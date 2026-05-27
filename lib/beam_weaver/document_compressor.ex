defmodule BeamWeaver.DocumentCompressor do
  @moduledoc """
  Behaviour and facade for query-aware document compression.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.DocumentLike
  alias BeamWeaver.Retriever
  alias BeamWeaver.Telemetry.AdapterEvent
  alias BeamWeaver.Telemetry.AdapterHelpers

  @callback compress(term(), [Document.t()], String.t(), keyword()) ::
              {:ok, [Document.t()]} | {:error, Error.t()}

  @spec compress(term(), Enumerable.t(), String.t(), keyword()) ::
          {:ok, [Document.t()]} | {:error, Error.t()}
  def compress(compressor, documents, query, opts \\ [])

  def compress(compressor, documents, query, opts) when is_binary(query) do
    with {:ok, docs} <- normalize_documents(documents) do
      result = compressor.__struct__.compress(compressor, docs, query, opts)

      emit(compressor, :compress, %{count: AdapterHelpers.result_count(result)}, %{
        query: query,
        result: result
      })

      result
    end
  rescue
    exception -> {:error, Error.new(:document_compressor_error, Exception.message(exception))}
  end

  def compress(_compressor, _documents, _query, _opts),
    do: {:error, Error.new(:invalid_compression_query, "compression query must be a string")}

  def async_compress(compressor, documents, query, opts \\ []) do
    Async.run(fn -> compress(compressor, documents, query, opts) end, opts)
  end

  def truncation(opts \\ []) do
    struct(BeamWeaver.DocumentCompressor.Truncation,
      max_characters: Keyword.get(opts, :max_characters, 1_000)
    )
  end

  def contextual_retriever(retriever, compressor, opts \\ []) do
    struct(BeamWeaver.DocumentCompressor.ContextualRetriever,
      retriever: retriever,
      compressor: compressor,
      opts: opts
    )
  end

  defp normalize_documents(documents) do
    documents
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case DocumentLike.to_document(value) do
        {:ok, document} -> {:cont, {:ok, [document | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, docs} -> {:ok, Enum.reverse(docs)}
      other -> other
    end
  end

  defp emit(compressor, operation, measurements, metadata) do
    BeamWeaver.Telemetry.emit(
      [:beam_weaver, :document_compressor, operation],
      measurements,
      %AdapterEvent{
        adapter: AdapterHelpers.adapter_name(compressor),
        operation: operation,
        query: Map.get(metadata, :query),
        result: AdapterHelpers.result_type(Map.get(metadata, :result)),
        error: AdapterHelpers.error_type(Map.get(metadata, :result))
      }
    )
  end

  defmodule Truncation do
    @moduledoc false
    @behaviour BeamWeaver.DocumentCompressor

    defstruct max_characters: 1_000

    @impl true
    def compress(%__MODULE__{max_characters: max}, documents, _query, _opts) do
      {:ok,
       Enum.map(documents, fn %Document{} = document ->
         if String.length(document.content) > max do
           %{document | content: String.slice(document.content, 0, max)}
         else
           document
         end
       end)}
    end
  end

  defmodule ContextualRetriever do
    @moduledoc false
    @behaviour BeamWeaver.Retriever

    defstruct [:retriever, :compressor, opts: []]

    @impl true
    def retrieve(%__MODULE__{} = wrapper, query, opts) do
      opts = Keyword.merge(wrapper.opts, opts)

      with {:ok, docs} <- Retriever.retrieve(wrapper.retriever, query, opts) do
        BeamWeaver.DocumentCompressor.compress(wrapper.compressor, docs, query, opts)
      end
    end
  end
end
