defmodule BeamWeaver.VectorStore do
  @moduledoc """
  Vector store behaviour and facade.
  """

  alias BeamWeaver.Adapter.Dispatch
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.RetrievalPolicy
  alias BeamWeaver.Telemetry.AdapterEvent
  alias BeamWeaver.Telemetry.AdapterHelpers

  @callback add_documents(term(), [Document.t()], keyword()) ::
              {:ok, [String.t()]} | {:error, Error.t()}
  @callback delete(term(), [String.t()], keyword()) :: :ok | {:error, Error.t()}
  @callback similarity_search(term(), String.t(), keyword()) ::
              {:ok, [Document.t()]} | {:error, Error.t()}
  @callback similarity_search_with_score(term(), String.t(), keyword()) ::
              {:ok, [{Document.t(), number()}]} | {:error, Error.t()}
  @callback similarity_search_by_vector(term(), [number()], keyword()) ::
              {:ok, [Document.t()]} | {:error, Error.t()}
  @callback max_marginal_relevance_search(term(), String.t(), keyword()) ::
              {:ok, [Document.t()]} | {:error, Error.t()}

  def from_documents(store_or_module, documents, opts \\ []) do
    with {:ok, store} <- build_store(store_or_module, opts),
         {:ok, _ids} <- add_documents(store, documents, opts) do
      {:ok, store}
    end
  end

  def from_texts(store_or_module, texts, opts \\ []) do
    with {:ok, store} <- build_store(store_or_module, opts),
         {:ok, _ids} <- add_texts(store, texts, opts) do
      {:ok, store}
    end
  end

  def embedding(%{embedding: embedding}), do: {:ok, embedding}
  def embedding(_store), do: {:ok, nil}

  @doc """
  Embeds and stores documents and returns their ids.

  `documents` is any enumerable of documents, such as the stream that
  `BeamWeaver.TextSplitter.split_documents/2` returns. Adding a document whose
  id is already stored replaces it.
  """
  @spec add_documents(term(), Enumerable.t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def add_documents(store, documents, opts \\ []) do
    with {:ok, documents} <- document_list(documents) do
      result = store_call(store, :add_documents, [documents, opts])

      emit(store, :add_documents, %{count: AdapterHelpers.result_count(result)}, %{
        result: result,
        metadata: %{input_count: length(documents)}
      })

      result
    end
  end

  def add_texts(store, texts, opts \\ []) do
    texts = List.wrap(texts)
    metadata = Keyword.get(opts, :metadatas, Keyword.get(opts, :metadata))
    ids = Keyword.get(opts, :ids, [])

    documents =
      texts
      |> Enum.with_index()
      |> Enum.map(fn {text, index} ->
        Document.new!(text,
          id: Enum.at(ids, index),
          metadata: metadata_for_index(metadata, index)
        )
      end)

    add_documents(store, documents, opts)
  end

  def delete(store, ids, opts \\ []) do
    ids = List.wrap(ids)
    result = store_call(store, :delete, [ids, opts])
    emit(store, :delete, %{count: length(ids)}, %{result: result})
    result
  end

  def get_by_ids(store, ids, opts \\ []) do
    case optional_store_call(
           store,
           :get_by_ids,
           [List.wrap(ids), opts],
           "vector store cannot fetch by ids"
         ) do
      {:called, result} -> result
      {:missing, {:error, _error} = error} -> error
    end
  end

  def search(store, query, search_type, opts \\ []) do
    case normalize_search_type(search_type) do
      {:ok, :similarity} ->
        similarity_search(store, query, opts)

      {:ok, :similarity_score} ->
        with {:ok, scored} <- similarity_search_with_score(store, query, opts) do
          threshold = Keyword.get(opts, :score_threshold)

          docs =
            scored
            |> Enum.filter(fn {_doc, score} -> is_nil(threshold) or score >= threshold end)
            |> Enum.map(&elem(&1, 0))

          {:ok, docs}
        end

      {:ok, :mmr} ->
        max_marginal_relevance_search(store, query, opts)

      {:error, _error} = error ->
        error
    end
  end

  def similarity_search(store, query, opts \\ []) do
    result = store_call(store, :similarity_search, [query, opts])
    emit_search(store, :similarity_search, query, opts, result)
    result
  end

  def similarity_search_with_score(store, query, opts \\ []) do
    result = store_call(store, :similarity_search_with_score, [query, opts])
    emit_search(store, :similarity_search_with_score, query, opts, result)
    result
  end

  def similarity_search_with_relevance_scores(store, query, opts \\ []) do
    with {:ok, scored} <- similarity_search_with_score(store, query, opts) do
      threshold = Keyword.get(opts, :score_threshold)

      scored =
        Enum.filter(scored, fn {_doc, score} ->
          is_nil(threshold) or score >= threshold
        end)

      {:ok, scored}
    end
  end

  def similarity_search_by_vector(store, vector, opts \\ []) do
    result = store_call(store, :similarity_search_by_vector, [vector, opts])
    emit_search(store, :similarity_search_by_vector, nil, opts, result)
    result
  end

  def similarity_search_with_score_by_vector(store, vector, opts \\ []) do
    case optional_store_call(
           store,
           :similarity_search_with_score_by_vector,
           [vector, opts],
           "vector store cannot perform scored search by vector"
         ) do
      {:called, result} ->
        emit_search(store, :similarity_search_with_score_by_vector, nil, opts, result)
        result

      {:missing, {:error, _error} = error} ->
        error
    end
  end

  def max_marginal_relevance_search(store, query, opts \\ []) do
    result = store_call(store, :max_marginal_relevance_search, [query, opts])
    emit_search(store, :max_marginal_relevance_search, query, opts, result)
    result
  end

  def max_marginal_relevance_search_by_vector(store, vector, opts \\ []) do
    case optional_store_call(
           store,
           :max_marginal_relevance_search_by_vector,
           [vector, opts],
           "vector store cannot perform MMR search by vector"
         ) do
      {:called, result} ->
        emit_search(store, :max_marginal_relevance_search_by_vector, nil, opts, result)
        result

      {:missing, {:error, _error} = error} ->
        error
    end
  end

  def as_retriever(store, opts \\ []) do
    struct(BeamWeaver.VectorStore.Retriever,
      store: store,
      policy: RetrievalPolicy.new!(opts)
    )
  end

  # Helpers shared by the bundled stores.

  @doc false
  def validate_documents(documents) do
    if Enum.all?(documents, &match?(%Document{}, &1)),
      do: :ok,
      else: {:error, Error.new(:invalid_documents, "expected BeamWeaver documents")}
  end

  @doc false
  def embed_documents(embedding, documents, opts),
    do: EmbeddingModel.embed_documents(embedding, Enum.map(documents, & &1.content), opts)

  # The explicit id at `index`, else the document's own id, else a content hash.
  @doc false
  def id_for(%Document{} = document, explicit_ids, index),
    do: to_string(Enum.at(explicit_ids, index) || document.id || stable_id(document))

  defp stable_id(%Document{} = document) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({document.content, document.metadata}))
    |> Base.encode16(case: :lower)
  end

  defp document_list(documents) when is_list(documents), do: {:ok, documents}

  defp document_list(documents) do
    if Enumerable.impl_for(documents),
      do: {:ok, Enum.to_list(documents)},
      else: {:error, Error.new(:invalid_documents, "expected an enumerable of BeamWeaver documents")}
  rescue
    # A lazy stream, such as a splitter's, raises while it is enumerated.
    exception -> {:error, Error.new(:invalid_documents, Exception.message(exception))}
  end

  defp metadata_for_index(nil, _index), do: %{}

  defp metadata_for_index(metadata, index) when is_list(metadata),
    do: Enum.at(metadata, index, %{})

  defp metadata_for_index(metadata, _index) when is_map(metadata), do: metadata
  defp metadata_for_index(_metadata, _index), do: %{}

  defp build_store(%{__struct__: _module} = store, _opts), do: {:ok, store}

  defp build_store(module, opts) when is_atom(module) do
    Code.ensure_loaded?(module)

    if function_exported?(module, :new, 1) do
      {:ok, module.new(opts)}
    else
      {:error, Error.new(:unsupported_vector_store_operation, "vector store adapter has no new/1")}
    end
  rescue
    exception -> {:error, Error.new(:vector_store_init_failed, Exception.message(exception))}
  end

  defp build_store(_store_or_module, _opts),
    do: {:error, Error.new(:invalid_vector_store, "expected vector store struct or module")}

  defp normalize_search_type(search_type)
       when search_type in [:similarity, "similarity", nil],
       do: {:ok, :similarity}

  defp normalize_search_type(search_type)
       when search_type in [
              :similarity_score,
              "similarity_score",
              :similarity_score_threshold,
              "similarity_score_threshold"
            ],
       do: {:ok, :similarity_score}

  defp normalize_search_type(search_type) when search_type in [:mmr, "mmr"], do: {:ok, :mmr}

  defp normalize_search_type(search_type),
    do:
      {:error,
       Error.new(:unsupported_vector_search_type, "unsupported vector search type", %{
         search_type: inspect(search_type)
       })}

  defp emit_search(store, operation, query, opts, result) do
    emit(store, operation, %{count: AdapterHelpers.result_count(result)}, %{
      query: query,
      filter: Keyword.get(opts, :filter),
      k: Keyword.get(opts, :k),
      result: result
    })
  end

  defp emit(store, operation, measurements, metadata) do
    result = Map.get(metadata, :result)

    BeamWeaver.Telemetry.emit(
      [:beam_weaver, :vector_store, operation],
      measurements,
      %AdapterEvent{
        adapter: AdapterHelpers.adapter_name(store),
        operation: operation,
        namespace: Map.get(store_metadata(store), :namespace),
        query: Map.get(metadata, :query),
        filter: Map.get(metadata, :filter),
        k: Map.get(metadata, :k),
        result: AdapterHelpers.result_type(result),
        error: AdapterHelpers.error_type(result),
        metadata: Map.merge(store_metadata(store), Map.get(metadata, :metadata, %{}))
      }
    )
  end

  defp store_metadata(store) do
    BeamWeaver.Adapter.Introspect.metadata(store)
  rescue
    _exception -> %{}
  end

  defp store_call(store, callback, args) do
    Dispatch.call(store, callback, args,
      error_type: :unsupported_vector_store_operation,
      missing_message: "vector store does not implement required callback",
      invalid_message: "expected vector store struct"
    )
  end

  defp optional_store_call(store, callback, args, missing_message) do
    dispatch_opts = [
      error_type: :unsupported_vector_store_operation,
      missing_message: missing_message,
      invalid_message: "expected vector store struct"
    ]

    case Dispatch.module(store, callback, length(args) + 1, dispatch_opts) do
      {:ok, _module} -> {:called, Dispatch.call(store, callback, args, dispatch_opts)}
      {:error, _error} = error -> {:missing, error}
    end
  end

  defmodule Retriever do
    @moduledoc false
    @behaviour BeamWeaver.Retriever

    defstruct [:store, :policy]

    def retrieve(%__MODULE__{store: store, policy: policy}, query, opts) do
      # Stores read the MMR trade-off as `lambda:`.
      {lambda, opts} = Keyword.pop(opts, :mmr_lambda, policy.mmr_lambda)

      opts =
        Keyword.merge(
          [k: policy.k, filter: policy.filter, score_threshold: policy.score_threshold, lambda: lambda],
          opts
        )

      BeamWeaver.VectorStore.search(store, query, policy.search_type, opts)
    end
  end
end
