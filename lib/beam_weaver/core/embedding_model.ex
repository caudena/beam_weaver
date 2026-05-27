defmodule BeamWeaver.Core.EmbeddingModel do
  @moduledoc """
  Behaviour for embedding model providers.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error

  @type vector :: [number()]

  @callback embed_documents(term(), [String.t()], keyword()) ::
              {:ok, [vector()]} | {:error, Error.t() | term()}
  @callback embed_query(term(), String.t(), keyword()) ::
              {:ok, vector()} | {:error, Error.t() | term()}

  @doc """
  Embeds multiple documents and validates vector shape.
  """
  @spec embed_documents(term(), [String.t()], keyword()) ::
          {:ok, [vector()]} | {:error, Error.t() | term()}
  def embed_documents(model, documents, opts \\ [])

  def embed_documents(model, documents, opts) when is_list(documents) do
    with :ok <- validate_documents(documents),
         {:ok, vectors} <- model.__struct__.embed_documents(model, documents, opts),
         :ok <- validate_vectors(vectors, expected_vector_count(model, documents, opts)) do
      {:ok, vectors}
    end
  end

  def embed_documents(_model, _documents, _opts),
    do: {:error, Error.new(:invalid_documents, "documents must be a list of strings")}

  @doc """
  Embeds one query and validates vector shape.
  """
  @spec embed_query(term(), String.t(), keyword()) ::
          {:ok, vector()} | {:error, Error.t() | term()}
  def embed_query(model, query, opts \\ [])

  def embed_query(model, query, opts) when is_binary(query) do
    with {:ok, vector} <- model.__struct__.embed_query(model, query, opts),
         :ok <- validate_vector(vector) do
      {:ok, vector}
    end
  end

  def embed_query(_model, _query, _opts),
    do: {:error, Error.new(:invalid_query, "query must be a string")}

  @doc """
  Starts async document embedding.
  """
  @spec async_embed_documents(term(), [String.t()], keyword()) :: Async.handle()
  def async_embed_documents(model, documents, opts \\ []) do
    Async.run_call(opts, &embed_documents(model, documents, &1))
  end

  @doc """
  Starts async query embedding.
  """
  @spec async_embed_query(term(), String.t(), keyword()) :: Async.handle()
  def async_embed_query(model, query, opts \\ []) do
    Async.run_call(opts, &embed_query(model, query, &1))
  end

  @doc """
  Starts an ordered async batch of query embeddings.
  """
  @spec async_batch_queries(term(), [String.t()], keyword()) :: [Async.handle()]
  def async_batch_queries(model, queries, opts \\ []) when is_list(queries) do
    Async.batch_call(queries, opts, &embed_query(model, &1, &2))
  end

  @doc """
  Validates returned embedding vectors.
  """
  @spec validate_vectors(term(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def validate_vectors(vectors, expected_count)
      when is_list(vectors) and length(vectors) == expected_count do
    case Enum.find_value(vectors, &vector_error/1) do
      nil -> :ok
      error -> {:error, error}
    end
  end

  def validate_vectors(_vectors, expected_count) do
    {:error,
     Error.new(:invalid_embeddings, "embedding count does not match input count", %{
       expected_count: expected_count
     })}
  end

  defp validate_documents(documents) do
    if Enum.all?(documents, &is_binary/1),
      do: :ok,
      else: {:error, Error.new(:invalid_documents, "documents must be strings")}
  end

  defp expected_vector_count(model, documents, opts) do
    if Keyword.get(opts, :skip_empty, Map.get(model, :skip_empty, false)) do
      Enum.count(documents, &(String.trim(&1) != ""))
    else
      length(documents)
    end
  end

  defp validate_vector(vector) do
    case vector_error(vector) do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp vector_error(vector) when is_list(vector) and vector != [] do
    if Enum.all?(vector, &is_number/1),
      do: nil,
      else: Error.new(:invalid_embedding, "embedding vectors must contain only numbers")
  end

  defp vector_error(_vector),
    do: Error.new(:invalid_embedding, "embedding vector must be a non-empty list")
end
