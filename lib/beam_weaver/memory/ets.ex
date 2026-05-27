defmodule BeamWeaver.Memory.ETS do
  @moduledoc """
  ETS implementation of `BeamWeaver.Memory.Store`.
  """

  @behaviour BeamWeaver.Memory.Store

  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.Memory.GetOp
  alias BeamWeaver.Memory.Item
  alias BeamWeaver.Memory.ListNamespacesOp
  alias BeamWeaver.Memory.MatchCondition
  alias BeamWeaver.Memory.PutOp
  alias BeamWeaver.Memory.Query
  alias BeamWeaver.Memory.SearchOp

  defstruct [:items, :vectors, ttl_config: %{}, index_config: nil]

  @type t :: %__MODULE__{
          items: :ets.tid(),
          vectors: :ets.tid(),
          ttl_config: map(),
          index_config: map() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    visibility = Keyword.get(opts, :visibility, :public)

    %__MODULE__{
      items: :ets.new(:beam_weaver_memory_items, [visibility, :set]),
      vectors: :ets.new(:beam_weaver_memory_vectors, [visibility, :set]),
      ttl_config: Keyword.get(opts, :ttl_config, Keyword.get(opts, :ttl, %{})),
      index_config: normalize_index_config(Keyword.get(opts, :index))
    }
  end

  @impl true
  def put(%__MODULE__{} = store, namespace, key, value, opts) do
    now = DateTime.utc_now()
    metadata = Keyword.get(opts, :metadata, %{})

    ttl =
      case Keyword.get(opts, :ttl, :not_provided) do
        :not_provided -> Map.get(store.ttl_config, :default_ttl)
        ttl -> ttl
      end

    item_key = {namespace, key}

    created_at =
      case :ets.lookup(store.items, item_key) do
        [{^item_key, existing}] -> existing.created_at
        [] -> now
      end

    item = %Item{
      namespace: namespace,
      key: key,
      value: value,
      metadata: metadata,
      created_at: created_at,
      updated_at: now,
      expires_at: Query.expires_at(ttl)
    }

    :ets.insert(store.items, {item_key, item})
    put_vectors(store, item, Keyword.get(opts, :index, nil))
    {:ok, item}
  end

  @impl true
  def get(%__MODULE__{} = store, namespace, key) do
    case :ets.lookup(store.items, {namespace, key}) do
      [{{^namespace, ^key}, item}] ->
        if Query.expired?(item) do
          :ets.delete(store.items, {namespace, key})
          :error
        else
          item = maybe_refresh_ttl(store, item)
          :ets.insert(store.items, {{namespace, key}, item})
          {:ok, item}
        end

      [] ->
        :error
    end
  end

  @impl true
  def delete(%__MODULE__{} = store, namespace, key) do
    :ets.delete(store.items, {namespace, key})
    :ets.delete(store.vectors, {namespace, key})
    :ok
  end

  @impl true
  def search(%__MODULE__{} = store, namespace, opts) do
    sweep_expired(store)

    items =
      store.items
      |> :ets.tab2list()
      |> Enum.map(fn {_key, item} -> item end)

    case vector_scores(store, namespace, items, opts) do
      {:ok, scores} -> Query.vector_search_items(items, namespace, scores, opts)
      :skip -> Query.search_items(items, namespace, opts)
      {:error, _error} = error -> error
    end
  end

  @impl true
  def list_namespaces(%__MODULE__{} = store, opts) do
    sweep_expired(store)

    namespaces =
      store.items
      |> :ets.tab2list()
      |> Enum.map(fn {{namespace, _key}, _item} -> namespace end)

    Query.list_namespaces(namespaces, opts)
  end

  @impl true
  def batch(%__MODULE__{} = store, ops) when is_list(ops) do
    Enum.map(ops, fn
      %GetOp{namespace: namespace, key: key} ->
        case get(store, namespace, key) do
          {:ok, item} -> item
          :error -> nil
        end

      %SearchOp{} = op ->
        search(store, op.namespace,
          filter: op.filter,
          limit: op.limit,
          offset: op.offset,
          query: op.query
        )

      %PutOp{namespace: namespace, key: key, value: nil} ->
        delete(store, namespace, key)
        nil

      %PutOp{} = op ->
        put(store, op.namespace, op.key, op.value,
          metadata: op.metadata,
          index: op.index,
          ttl: op.ttl
        )

        nil

      %ListNamespacesOp{} = op ->
        list_namespaces(store, list_namespace_opts(op))
    end)
  end

  defp list_namespace_opts(%ListNamespacesOp{} = op) do
    {prefix, suffix} =
      Enum.reduce(op.match_conditions || [], {[], []}, fn
        %MatchCondition{type: :prefix, path: path}, {_prefix, suffix} -> {path, suffix}
        %MatchCondition{type: "prefix", path: path}, {_prefix, suffix} -> {path, suffix}
        %MatchCondition{type: :suffix, path: path}, {prefix, _suffix} -> {prefix, path}
        %MatchCondition{type: "suffix", path: path}, {prefix, _suffix} -> {prefix, path}
      end)

    [
      prefix: prefix,
      suffix: suffix,
      max_depth: op.max_depth,
      limit: op.limit,
      offset: op.offset
    ]
  end

  defp maybe_refresh_ttl(_store, %{expires_at: nil} = item), do: item

  defp maybe_refresh_ttl(store, item) do
    if Map.get(store.ttl_config, :refresh_on_read, true) do
      Query.refresh_expiry(item, Map.get(store.ttl_config, :default_ttl))
    else
      item
    end
  end

  defp normalize_index_config(nil), do: nil

  defp normalize_index_config(config) when is_list(config) do
    config |> Map.new() |> normalize_index_config()
  end

  defp normalize_index_config(config) when is_map(config) do
    embed = Map.get(config, :embed) || Map.get(config, "embed") || Map.get(config, :embedding)
    fields = Map.get(config, :fields, Map.get(config, "fields", ["$"]))
    dims = Map.get(config, :dims, Map.get(config, "dims", Map.get(config, :dimensions)))

    %{embed: embed, fields: List.wrap(fields), dims: dims}
  end

  defp put_vectors(%__MODULE__{index_config: nil}, _item, _index), do: :ok

  defp put_vectors(%__MODULE__{} = store, %Item{} = item, index) do
    fields = effective_index_fields(store.index_config, index)

    if fields == [] do
      :ets.delete(store.vectors, {item.namespace, item.key})
    else
      texts = indexed_texts(item.value, fields)

      case embed_documents(store.index_config, texts) do
        {:ok, vectors} ->
          entries =
            texts
            |> Enum.zip(vectors)
            |> Enum.map(fn {text, vector} -> %{text: text, vector: vector} end)

          :ets.insert(store.vectors, {{item.namespace, item.key}, entries})
          :ok

        {:error, _error} ->
          :ets.delete(store.vectors, {item.namespace, item.key})
          :ok
      end
    end
  end

  defp effective_index_fields(_config, false), do: []
  defp effective_index_fields(_config, fields) when is_list(fields), do: fields
  defp effective_index_fields(config, _index), do: Map.get(config, :fields, ["$"])

  defp indexed_texts(value, fields) do
    fields
    |> Enum.flat_map(&Query.get_text_at_path(value, to_string(&1)))
    |> Enum.reject(&(&1 == ""))
  end

  defp embed_documents(_config, []), do: {:ok, []}

  defp embed_documents(%{embed: nil}, texts), do: {:ok, Enum.map(texts, &fallback_vector/1)}

  defp embed_documents(%{embed: embed}, texts) do
    if is_struct(embed) do
      EmbeddingModel.embed_documents(embed, texts)
    else
      {:ok, Enum.map(texts, &fallback_vector/1)}
    end
  end

  defp vector_scores(%__MODULE__{index_config: nil}, _namespace, _items, _opts), do: :skip

  defp vector_scores(%__MODULE__{} = store, namespace, items, opts) do
    query = Keyword.get(opts, :query)

    if is_nil(query) do
      :skip
    else
      query = to_string(query)

      with {:ok, query_vector} <- embed_query(store.index_config, query) do
        indexed_scores =
          store.vectors
          |> :ets.tab2list()
          |> Enum.flat_map(fn {{item_namespace, key}, entries} ->
            if Query.namespace_prefix?(item_namespace, namespace) do
              score = best_score(query_vector, entries)
              [{{item_namespace, key}, score}]
            else
              []
            end
          end)

        indexed_keys = MapSet.new(indexed_scores, fn {key, _score} -> key end)

        nil_scores =
          items
          |> Enum.reject(&MapSet.member?(indexed_keys, {&1.namespace, &1.key}))
          |> Enum.map(&{{&1.namespace, &1.key}, nil})

        {:ok, indexed_scores ++ nil_scores}
      end
    end
  end

  defp embed_query(%{embed: nil}, query), do: {:ok, fallback_vector(query)}

  defp embed_query(%{embed: embed}, query) do
    if is_struct(embed) do
      EmbeddingModel.embed_query(embed, query)
    else
      {:ok, fallback_vector(query)}
    end
  end

  defp best_score(_query_vector, []), do: nil

  defp best_score(query_vector, entries) do
    entries
    |> Enum.map(&cosine(query_vector, &1.vector))
    |> Enum.max(fn -> nil end)
  end

  defp fallback_vector(text) do
    text = String.downcase(to_string(text))
    chars = String.to_charlist(text)

    for bucket <- 0..63 do
      Enum.count(chars, &(rem(&1, 64) == bucket))
    end
  end

  defp cosine(left, right) when is_list(left) and is_list(right) do
    pairs = Enum.zip(left, right)
    dot = Enum.reduce(pairs, 0.0, fn {a, b}, acc -> acc + a * b end)
    left_norm = :math.sqrt(Enum.reduce(left, 0.0, fn value, acc -> acc + value * value end))
    right_norm = :math.sqrt(Enum.reduce(right, 0.0, fn value, acc -> acc + value * value end))

    if left_norm == 0.0 or right_norm == 0.0 do
      0.0
    else
      dot / (left_norm * right_norm)
    end
  end

  defp cosine(_left, _right), do: 0.0

  defp sweep_expired(store) do
    for {{namespace, key}, item} <- :ets.tab2list(store.items), Query.expired?(item) do
      :ets.delete(store.items, {namespace, key})
      :ets.delete(store.vectors, {namespace, key})
    end

    :ok
  end
end
