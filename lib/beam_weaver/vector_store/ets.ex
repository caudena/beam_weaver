defmodule BeamWeaver.VectorStore.ETS do
  @moduledoc """
  ETS-backed in-memory vector store for tests, examples, and local agents.
  """

  @behaviour BeamWeaver.VectorStore

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.VectorStore.Filter
  alias BeamWeaver.VectorStore.Scoring

  defstruct [:table, :embedding, namespace: :default]

  @type t :: %__MODULE__{
          table: :ets.tid(),
          embedding: term(),
          namespace: term()
        }

  def new(opts \\ []) do
    table =
      Keyword.get_lazy(opts, :table, fn ->
        :ets.new(:beam_weaver_vector_store, [:set, :public, {:read_concurrency, true}])
      end)

    %__MODULE__{
      table: table,
      embedding: Keyword.fetch!(opts, :embedding),
      namespace: Keyword.get(opts, :namespace, :default)
    }
  end

  @impl true
  def add_documents(%__MODULE__{} = store, documents, opts) do
    with :ok <- validate_documents(documents),
         {:ok, vectors} <- embed_documents(store.embedding, documents, opts) do
      explicit_ids = Keyword.get(opts, :ids, [])

      ids =
        documents
        |> Enum.zip(vectors)
        |> Enum.with_index()
        |> Enum.map(fn {{document, vector}, index} ->
          id = id_for(document, explicit_ids, index)

          :ets.insert(
            store.table,
            {{store.namespace, id}, %{document: %{document | id: id}, vector: vector}}
          )

          id
        end)

      {:ok, ids}
    end
  end

  @impl true
  def delete(%__MODULE__{} = store, ids, _opts) do
    Enum.each(ids, &:ets.delete(store.table, {store.namespace, &1}))
    :ok
  end

  def get_by_ids(%__MODULE__{} = store, ids, _opts) do
    documents =
      ids
      |> Enum.flat_map(fn id ->
        case :ets.lookup(store.table, {store.namespace, id}) do
          [{_key, %{document: document}}] -> [document]
          [] -> []
        end
      end)

    {:ok, documents}
  end

  @doc """
  Dumps the current namespace to a JSON file.

  The embedding model is intentionally not serialized; callers provide it again
  when loading so runtime dependencies stay explicit.
  """
  @spec dump(t(), Path.t()) :: :ok | {:error, Error.t()}
  def dump(%__MODULE__{} = store, path) when is_binary(path) do
    payload = %{
      "version" => 1,
      "namespace" => to_string(store.namespace),
      "entries" =>
        store
        |> entries(%{})
        |> Enum.map(fn %{document: document, vector: vector} ->
          %{
            "id" => document.id,
            "content" => document.content,
            "metadata" => document.metadata,
            "vector" => vector
          }
        end)
    }

    case BeamWeaver.JSON.encode(payload) do
      {:ok, json} ->
        case File.write(path, json) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error,
             Error.new(:vector_store_dump_failed, "failed to write vector store dump", %{
               reason: reason
             })}
        end

      {:error, reason} ->
        {:error,
         Error.new(:vector_store_dump_failed, "failed to encode vector store dump", %{
           reason: Exception.message(reason)
         })}
    end
  end

  @doc """
  Loads a JSON dump into a new ETS vector store.
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def load(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, body} <- read_dump(path),
         {:ok, payload} <- decode_dump(body),
         {:ok, entries} <- dump_entries(payload) do
      namespace = Keyword.get(opts, :namespace, Map.get(payload, "namespace", :default))
      store = new(Keyword.put(opts, :namespace, namespace))

      Enum.each(entries, fn entry ->
        document =
          Document.new!(entry["content"] || "",
            id: entry["id"],
            metadata: entry["metadata"] || %{}
          )

        :ets.insert(
          store.table,
          {{store.namespace, document.id}, %{document: document, vector: entry["vector"] || []}}
        )
      end)

      {:ok, store}
    end
  end

  @impl true
  def similarity_search(%__MODULE__{} = store, query, opts) do
    with {:ok, scored} <- similarity_search_with_score(store, query, opts) do
      {:ok, Enum.map(scored, &elem(&1, 0))}
    end
  end

  @impl true
  def similarity_search_with_score(%__MODULE__{} = store, query, opts) do
    with {:ok, vector} <- EmbeddingModel.embed_query(store.embedding, query, opts) do
      {:ok, scored_documents(store, vector, opts)}
    end
  end

  @impl true
  def similarity_search_by_vector(%__MODULE__{} = store, vector, opts) do
    {:ok, store |> scored_documents(vector, opts) |> Enum.map(&elem(&1, 0))}
  end

  def similarity_search_with_score_by_vector(%__MODULE__{} = store, vector, opts) do
    {:ok, scored_documents(store, vector, opts)}
  end

  @impl true
  def max_marginal_relevance_search(%__MODULE__{} = store, query, opts) do
    with {:ok, query_vector} <- EmbeddingModel.embed_query(store.embedding, query, opts) do
      max_marginal_relevance_search_by_vector(store, query_vector, opts)
    end
  end

  def max_marginal_relevance_search_by_vector(%__MODULE__{} = store, query_vector, opts) do
    k = Keyword.get(opts, :k, 4)
    fetch_k = Keyword.get(opts, :fetch_k, max(k * 4, k))

    lambda =
      Keyword.get(
        opts,
        :lambda,
        Keyword.get(opts, :mmr_lambda, Keyword.get(opts, :lambda_mult, 0.5))
      )

    candidates =
      store
      |> entries(Keyword.get(opts, :filter, %{}))
      |> Enum.map(fn %{document: document, vector: vector} ->
        {document, vector, Scoring.cosine(query_vector, vector)}
      end)
      |> Enum.sort_by(fn {_doc, _vector, score} -> -score end)
      |> Enum.take(fetch_k)

    {:ok, query_vector |> Scoring.mmr(candidates, k, lambda, []) |> Enum.map(&elem(&1, 0))}
  end

  defp scored_documents(store, vector, opts) do
    k = Keyword.get(opts, :k, 4)
    filter = Keyword.get(opts, :filter, %{})

    store
    |> entries(filter)
    |> Enum.map(fn %{document: document, vector: stored_vector} ->
      {document, Scoring.cosine(vector, stored_vector)}
    end)
    |> Enum.sort_by(fn {_document, score} -> -score end)
    |> Enum.take(k)
  end

  defp entries(%__MODULE__{} = store, filter) do
    store.table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{namespace, _id}, entry} when namespace == store.namespace ->
        if filter_match?(entry.document, filter), do: [entry], else: []

      _other ->
        []
    end)
  end

  defp embed_documents(embedding, documents, opts) do
    documents
    |> Enum.map(& &1.content)
    |> then(&EmbeddingModel.embed_documents(embedding, &1, opts))
  end

  defp filter_match?(_document, filter) when filter in [%{}, nil], do: true

  defp filter_match?(%Document{} = document, filter) when is_function(filter, 1) do
    filter.(document) == true
  rescue
    _exception -> false
  end

  defp filter_match?(%Document{} = document, filter), do: Filter.match?(document.metadata, filter)

  defp read_dump(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         Error.new(:vector_store_load_failed, "failed to read vector store dump", %{
           reason: reason
         })}
    end
  end

  defp decode_dump(body) do
    case BeamWeaver.JSON.decode(body) do
      {:ok, %{} = payload} ->
        {:ok, payload}

      {:ok, _other} ->
        {:error, Error.new(:vector_store_load_failed, "vector store dump must be a JSON object")}

      {:error, reason} ->
        {:error,
         Error.new(:vector_store_load_failed, "failed to decode vector store dump", %{
           reason: Exception.message(reason)
         })}
    end
  end

  defp dump_entries(%{"entries" => entries}) when is_list(entries), do: {:ok, entries}

  defp dump_entries(_payload),
    do: {:error, Error.new(:vector_store_load_failed, "vector store dump missing entries")}

  defp validate_documents(documents) do
    if Enum.all?(documents, &match?(%Document{}, &1)),
      do: :ok,
      else: {:error, Error.new(:invalid_documents, "expected BeamWeaver documents")}
  end

  defp id_for(%Document{} = document, explicit_ids, index) do
    explicit_ids
    |> Enum.at(index)
    |> Kernel.||(document.id)
    |> Kernel.||(stable_id(document))
    |> to_string()
  end

  defp stable_id(%Document{} = document) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({document.content, document.metadata}))
    |> Base.encode16(case: :lower)
  end
end
