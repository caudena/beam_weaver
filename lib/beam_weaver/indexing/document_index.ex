defprotocol BeamWeaver.Indexing.DocumentIndex.Backend do
  @moduledoc """
  Protocol dispatch for read/write document indexes.
  """

  def upsert(index, documents, opts)
  def delete(index, ids, opts)
  def get(index, ids, opts)
end

defmodule BeamWeaver.Indexing.DocumentIndex do
  @moduledoc """
  Read/write document index behaviour.

  This is distinct from `BeamWeaver.DocumentIndex`, which orchestrates a full
  loader/splitter/vector-store indexing pipeline. This module models the smaller
  LangChain `DocumentIndex` read/write contract in an Elixir-native tagged-result
  shape.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Indexing.DocumentIndex.Backend, as: DocumentIndexBackend

  @type upsert_response :: %{succeeded: [String.t()], failed: [term()]}
  @type delete_response :: %{
          succeeded: [String.t()],
          failed: [term()],
          num_deleted: non_neg_integer(),
          num_failed: non_neg_integer()
        }

  @callback upsert(term(), [Document.t()], keyword()) ::
              {:ok, upsert_response()} | {:error, Error.t()}
  @callback delete(term(), [String.t()] | nil, keyword()) ::
              {:ok, delete_response()} | {:error, Error.t()}
  @callback get(term(), [String.t()], keyword()) :: {:ok, [Document.t()]} | {:error, Error.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Indexing.DocumentIndex

      defimpl BeamWeaver.Indexing.DocumentIndex.Backend, for: __MODULE__ do
        def upsert(index, documents, opts), do: @for.upsert(index, documents, opts)
        def delete(index, ids, opts), do: @for.delete(index, ids, opts)
        def get(index, ids, opts), do: @for.get(index, ids, opts)
      end
    end
  end

  def upsert(index, documents, opts \\ []),
    do: DocumentIndexBackend.upsert(index, documents, opts)

  def delete(index, ids \\ nil, opts \\ []),
    do: DocumentIndexBackend.delete(index, ids, opts)

  def get(index, ids, opts \\ []),
    do: DocumentIndexBackend.get(index, ids, opts)

  def async_upsert(index, documents, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> upsert(index, documents, call_opts) end, async_opts)
  end

  def async_delete(index, ids \\ nil, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> delete(index, ids, call_opts) end, async_opts)
  end

  def async_get(index, ids, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> get(index, ids, call_opts) end, async_opts)
  end
end
