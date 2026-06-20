defmodule BeamWeaver.DocumentIndex do
  @moduledoc """
  Explicit document indexing pipeline.

  A document index is a small orchestration struct. Callers provide each moving
  part explicitly: loader, parser, splitter, transformers, vector store, and
  record manager.
  """

  alias BeamWeaver.BlobLoader
  alias BeamWeaver.BlobParser
  alias BeamWeaver.Core.Error
  alias BeamWeaver.DocumentLike
  alias BeamWeaver.DocumentLoader
  alias BeamWeaver.DocumentTransformer
  alias BeamWeaver.Indexing
  alias BeamWeaver.TextSplitter

  defstruct [
    :loader,
    :blob_loader,
    :blob_parser,
    :splitter,
    :vector_store,
    :record_manager,
    transformers: [],
    indexing_opts: [],
    namespace: :default
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      loader: Keyword.get(opts, :loader),
      blob_loader: Keyword.get(opts, :blob_loader),
      blob_parser: Keyword.get(opts, :blob_parser),
      splitter: Keyword.get(opts, :splitter),
      transformers: Keyword.get(opts, :transformers, []),
      vector_store: Keyword.fetch!(opts, :vector_store),
      record_manager: Keyword.get(opts, :record_manager),
      indexing_opts: Keyword.get(opts, :indexing_opts, []),
      namespace: Keyword.get(opts, :namespace, :default)
    }
  end

  @spec run(t(), term(), keyword()) :: {:ok, BeamWeaver.Indexing.Result.t()} | {:error, Error.t()}
  def run(%__MODULE__{} = index, input \\ nil, opts \\ []) do
    with {:ok, docs} <- load_documents(index, input, opts),
         {:ok, docs} <- maybe_split(index.splitter, docs, opts),
         {:ok, docs} <- transform_all(index.transformers, docs, opts) do
      Indexing.index(
        index.vector_store,
        Enum.to_list(docs),
        [record_manager: index.record_manager, namespace: index.namespace]
        |> Keyword.merge(index.indexing_opts)
        |> Keyword.merge(opts)
      )
    end
  rescue
    exception ->
      {:error, Error.new(:document_index_error, Exception.message(exception))}
  end

  defp load_documents(%__MODULE__{} = index, nil, opts) do
    cond do
      not is_nil(index.loader) ->
        DocumentLoader.load(index.loader, opts)

      not is_nil(index.blob_loader) and not is_nil(index.blob_parser) ->
        with {:ok, blobs} <- BlobLoader.load(index.blob_loader, opts) do
          {:ok,
           Stream.flat_map(blobs, fn blob ->
             case BlobParser.parse(index.blob_parser, blob, opts) do
               {:ok, docs} -> docs
               {:error, error} -> raise RuntimeError, message: error.message
             end
           end)}
        end

      true ->
        {:error, Error.new(:invalid_document_index, "document index requires a loader or input")}
    end
  end

  defp load_documents(_index, input, _opts) do
    {:ok,
     Stream.map(List.wrap(input), fn value ->
       case DocumentLike.to_document(value) do
         {:ok, document} -> document
         {:error, error} -> raise RuntimeError, message: error.message
       end
     end)}
  end

  defp maybe_split(nil, docs, _opts), do: {:ok, docs}

  defp maybe_split(splitter, docs, _opts) do
    TextSplitter.split_documents(splitter, docs)
  end

  defp transform_all(transformers, docs, opts) do
    Enum.reduce_while(List.wrap(transformers), {:ok, docs}, fn transformer, {:ok, stream} ->
      case DocumentTransformer.transform(transformer, stream, opts) do
        {:ok, transformed} -> {:cont, {:ok, transformed}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
