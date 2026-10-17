defmodule BeamWeaver.Memory.ETS do
  @moduledoc """
  ETS implementation of `BeamWeaver.Memory.Store`.

  ## Options

    * `:default_ttl` - lifetime in minutes of records put without `ttl:`;
      `nil` (the default) keeps them until they are deleted
    * `:refresh_ttl` - whether reading a record with `get` or `search` starts
      its lifetime again (default `false`)
    * `:index` - an embedding index for semantic search:
      `[embed: embeddings, fields: ["text"]]`
    * `:visibility` - the ETS table access, `:public` by default

  `BeamWeaver.Memory.Ecto` takes the same `:default_ttl` and `:refresh_ttl`.
  """

  @behaviour BeamWeaver.Memory.Store

  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.Memory.Item
  alias BeamWeaver.Memory.Query

  defstruct [:items, :vectors, default_ttl: nil, refresh_ttl: false, index_config: nil]

  @type t :: %__MODULE__{
          items: :ets.tid(),
          vectors: :ets.tid(),
          default_ttl: number() | nil,
          refresh_ttl: boolean(),
          index_config: map() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, [:index, visibility: :public, default_ttl: nil, refresh_ttl: false])
    visibility = Keyword.fetch!(opts, :visibility)

    %__MODULE__{
      items: :ets.new(:beam_weaver_memory_items, [visibility, :set]),
      vectors: :ets.new(:beam_weaver_memory_vectors, [visibility, :set]),
      default_ttl: Keyword.fetch!(opts, :default_ttl),
      refresh_ttl: Query.refresh_ttl_option!(Keyword.fetch!(opts, :refresh_ttl)),
      index_config: normalize_index_config(Keyword.get(opts, :index))
    }
  end

  @impl true
  def put(%__MODULE__{} = store, namespace, key, value, opts) do
    now = DateTime.utc_now()
    metadata = Keyword.get(opts, :metadata, %{})

    ttl = with :not_provided <- Keyword.get(opts, :ttl, :not_provided), do: store.default_ttl
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
      expires_at: Query.expires_at(ttl),
      ttl: ttl
    }

    :ets.insert(store.items, {item_key, item})
    put_vectors(store, item, Keyword.get(opts, :index, nil))
    {:ok, item}
  end

  @impl true
  def get(%__MODULE__{} = store, namespace, key), do: get_item(store, namespace, key, store.refresh_ttl)

  defp get_item(store, namespace, key, refresh_ttl) do
    case :ets.lookup(store.items, {namespace, key}) do
      [{{^namespace, ^key}, item}] ->
        cond do
          Query.expired?(item) ->
            delete_expired(store, item)
            :error

          refresh_ttl ->
            {:ok, refresh_item(store, item)}

          true ->
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

  @doc false
  @spec sweep_expired(t(), keyword()) :: {:ok, non_neg_integer()}
  def sweep_expired(%__MODULE__{} = store, _opts \\ []) do
    expired = for {_key, item} <- :ets.tab2list(store.items), Query.expired?(item), do: item
    {:ok, Enum.count(expired, &delete_expired(store, &1))}
  end

  # The records left once the expired ones are deleted, from one read of the
  # table.
  defp live_items(store) do
    {expired, live} = store.items |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.split_with(&Query.expired?/1)
    Enum.each(expired, &delete_expired(store, &1))
    live
  end

  # Deletes `item` only while it is the stored record, so the record of a put
  # that ran since it was read is kept. True when it was deleted.
  defp delete_expired(store, %Item{} = item) do
    key = {item.namespace, item.key}
    unchanged = [{{key, :"$1"}, [{:"=:=", :"$1", {:const, item}}], [true]}]

    if :ets.select_delete(store.items, unchanged) == 1 do
      :ets.delete(store.vectors, key)
      true
    else
      false
    end
  end

  @impl true
  def search(%__MODULE__{} = store, namespace, opts) do
    items = live_items(store)

    case vector_scores(store, namespace, items, opts) do
      {:ok, scores} -> items |> Query.vector_search_items(namespace, scores, opts) |> maybe_refresh(store, opts)
      :skip -> items |> Query.search_items(namespace, opts) |> maybe_refresh(store, opts)
      {:error, _error} = error -> error
    end
  end

  @impl true
  def list_namespaces(%__MODULE__{} = store, opts) do
    store |> live_items() |> Enum.map(& &1.namespace) |> Query.list_namespaces(opts)
  end

  @impl true
  def batch(%__MODULE__{} = store, ops) when is_list(ops), do: Query.batch(store, ops, &get_item(store, &1, &2, &3))

  defp maybe_refresh(results, store, opts) do
    if Query.refresh_ttl?(store, Keyword.get(opts, :refresh_ttl)),
      do: Enum.map(results, &refresh_item(store, &1)),
      else: results
  end

  # Starts a record's lifetime again from now; records without one keep none.
  # `item` may be the `SearchItem` of a semantic search. The stored record gets
  # its own lifetime again, and only if it is still the record looked up: a
  # `put` that runs meanwhile is kept as it was put.
  defp refresh_item(_store, %{ttl: nil} = item), do: item

  defp refresh_item(store, item) do
    key = {item.namespace, item.key}

    case :ets.lookup(store.items, key) do
      [{^key, %Item{ttl: ttl} = stored}] when not is_nil(ttl) ->
        refreshed = %{stored | expires_at: Query.expires_at(ttl)}
        unchanged = [{{key, :"$1"}, [{:"=:=", :"$1", {:const, stored}}], [{:const, {key, refreshed}}]}]

        if :ets.select_replace(store.items, unchanged) == 1,
          do: %{item | expires_at: refreshed.expires_at},
          else: item

      _other ->
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
          entries = Enum.zip_with(texts, vectors, &%{text: &1, vector: &2})
          :ets.insert(store.vectors, {{item.namespace, item.key}, entries})

        {:error, _error} ->
          :ets.delete(store.vectors, {item.namespace, item.key})
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
  defp embed_documents(%{embed: embed}, texts) when is_struct(embed), do: EmbeddingModel.embed_documents(embed, texts)
  defp embed_documents(_config, texts), do: {:ok, Enum.map(texts, &fallback_vector/1)}

  defp vector_scores(%__MODULE__{index_config: nil}, _namespace, _items, _opts), do: :skip

  defp vector_scores(%__MODULE__{} = store, namespace, items, opts) do
    query = Keyword.get(opts, :query)

    if is_nil(query) do
      :skip
    else
      query = to_string(query)

      with {:ok, query_vector} <- embed_query(store.index_config, query) do
        indexed_scores =
          for {{item_namespace, _key} = item_key, entries} <- :ets.tab2list(store.vectors),
              Query.namespace_prefix?(item_namespace, namespace),
              do: {item_key, best_score(query_vector, entries)}

        indexed_keys = MapSet.new(indexed_scores, fn {key, _score} -> key end)

        nil_scores =
          items
          |> Enum.reject(&MapSet.member?(indexed_keys, {&1.namespace, &1.key}))
          |> Enum.map(&{{&1.namespace, &1.key}, nil})

        {:ok, indexed_scores ++ nil_scores}
      end
    end
  end

  defp embed_query(%{embed: embed}, query) when is_struct(embed), do: EmbeddingModel.embed_query(embed, query)
  defp embed_query(_config, query), do: {:ok, fallback_vector(query)}

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
end
