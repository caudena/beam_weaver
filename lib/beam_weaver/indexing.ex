defmodule BeamWeaver.Indexing do
  @moduledoc """
  Deterministic document indexing helpers.

  Indexing is an orchestration layer over an explicit record manager and an
  explicit vector store. Cleanup never runs unless requested.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Indexing.Cleanup
  alias BeamWeaver.Indexing.Documents
  alias BeamWeaver.Indexing.Executor
  alias BeamWeaver.Indexing.Hash
  alias BeamWeaver.Indexing.Planner

  defstruct added: 0, updated: 0, skipped: 0, deleted: 0, errors: []

  def index(vector_store, documents, opts \\ []) do
    namespace = Keyword.get(opts, :namespace, :default)
    record_manager = Keyword.get(opts, :record_manager)
    force_update = Keyword.get(opts, :force_update, false)

    with {:ok, docs} <- Documents.normalize(documents, opts),
         {:ok, planned} <- Planner.plan(record_manager, docs, namespace, force_update, opts),
         {:ok, result} <-
           Executor.apply_plan(vector_store, record_manager, planned, namespace, opts) do
      Cleanup.apply(vector_store, record_manager, planned, result, namespace, opts)
    end
  rescue
    exception -> {:error, Error.new(:indexing_error, Exception.message(exception))}
  end

  def async_index(vector_store, documents, opts \\ []) do
    Async.run_call(opts, &index(vector_store, documents, &1))
  end

  @doc "Returns the deterministic hash for a document."
  defdelegate hash(doc), to: Hash, as: :document_hash

  @doc """
  Returns a copy of a document with a deterministic id.

  This is the BeamWeaver-native public surface for hash-addressed indexing.
  Callers can provide a hashing algorithm or a custom one-arity encoder.
  """
  @spec with_hashed_id(Document.t(), keyword()) :: {:ok, Document.t()} | {:error, Error.t()}
  defdelegate with_hashed_id(document, opts \\ []), to: Hash

  @doc """
  Hashes text with the selected stable document-id algorithm.
  """
  @spec hash_string(String.t(), atom()) :: {:ok, String.t()} | {:error, Error.t()}
  defdelegate hash_string(text, algorithm), to: Hash
end
