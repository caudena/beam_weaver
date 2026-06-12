defmodule BeamWeaver.DocumentTransformer do
  @moduledoc """
  Behaviour and facade for lazy document transformations.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.DocumentLike
  alias BeamWeaver.Telemetry.AdapterEvent
  alias BeamWeaver.Telemetry.AdapterHelpers

  @callback transform(term(), Enumerable.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t()}

  @spec transform(term(), Enumerable.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def transform(transformer, documents, opts \\ []) do
    result = transformer.__struct__.transform(transformer, documents, opts)
    emit(transformer, :transform, %{count: result_count(result)}, %{result: result})
    result
  rescue
    exception -> {:error, Error.new(:document_transformer_error, Exception.message(exception))}
  end

  def async_transform(transformer, documents, opts \\ []) do
    Async.run(fn -> transform(transformer, documents, opts) end, opts)
  end

  def metadata_map(fun) when is_function(fun, 1) do
    struct(BeamWeaver.DocumentTransformer.MetadataMap, fun: fun)
  end

  def metadata_filter(predicate) when is_function(predicate, 1) do
    struct(BeamWeaver.DocumentTransformer.MetadataFilter, predicate: predicate)
  end

  def content_map(fun) when is_function(fun, 1) do
    struct(BeamWeaver.DocumentTransformer.ContentMap, fun: fun)
  end

  @doc false
  def normalize_document!(value) do
    case DocumentLike.to_document(value) do
      {:ok, %Document{} = document} -> document
      {:error, error} -> raise RuntimeError, message: error.message
    end
  end

  defp emit(transformer, operation, measurements, metadata) do
    BeamWeaver.Telemetry.emit(
      [:beam_weaver, :document_transformer, operation],
      measurements,
      %AdapterEvent{
        adapter: AdapterHelpers.adapter_name(transformer),
        operation: operation,
        result: AdapterHelpers.result_type(Map.get(metadata, :result)),
        error: AdapterHelpers.error_type(Map.get(metadata, :result))
      }
    )
  end

  defp result_count({:ok, enumerable}) do
    if is_list(enumerable), do: length(enumerable), else: 0
  end

  defp result_count(_result), do: 0

  defmodule MetadataMap do
    @moduledoc false
    @behaviour BeamWeaver.DocumentTransformer

    defstruct [:fun]

    @impl true
    def transform(%__MODULE__{fun: fun}, documents, _opts) do
      {:ok,
       Stream.map(documents, fn value ->
         document = BeamWeaver.DocumentTransformer.normalize_document!(value)
         metadata = fun.(document.metadata)

         unless is_map(metadata) do
           raise RuntimeError, "metadata transformer must return a map"
         end

         %{document | metadata: metadata}
       end)}
    end
  end

  defmodule MetadataFilter do
    @moduledoc false
    @behaviour BeamWeaver.DocumentTransformer

    defstruct [:predicate]

    @impl true
    def transform(%__MODULE__{predicate: predicate}, documents, _opts) do
      {:ok,
       Stream.filter(documents, fn value ->
         document = BeamWeaver.DocumentTransformer.normalize_document!(value)
         predicate.(document.metadata) == true
       end)
       |> Stream.map(&BeamWeaver.DocumentTransformer.normalize_document!/1)}
    end
  end

  defmodule ContentMap do
    @moduledoc false
    @behaviour BeamWeaver.DocumentTransformer

    defstruct [:fun]

    @impl true
    def transform(%__MODULE__{fun: fun}, documents, _opts) do
      {:ok,
       Stream.map(documents, fn value ->
         document = BeamWeaver.DocumentTransformer.normalize_document!(value)
         content = fun.(document.content)

         unless is_binary(content) do
           raise RuntimeError, "content transformer must return a string"
         end

         %{document | content: content}
       end)}
    end
  end
end
