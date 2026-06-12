defmodule BeamWeaver.Models.FunctionEmbeddingModel do
  @moduledoc """
  Behaviour-backed embedding model for explicit embedding functions.
  """

  @behaviour BeamWeaver.Core.EmbeddingModel

  alias BeamWeaver.Core.Error

  defstruct [:embed_documents, :embed_query]

  @type t :: %__MODULE__{
          embed_documents: function(),
          embed_query: function() | nil
        }

  @spec new(function(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(embed_documents, opts \\ [])

  def new(embed_documents, opts)
      when is_function(embed_documents, 1) or is_function(embed_documents, 2) do
    embed_query = Keyword.get(opts, :embed_query)

    if is_nil(embed_query) or is_function(embed_query, 1) or is_function(embed_query, 2) do
      {:ok, %__MODULE__{embed_documents: embed_documents, embed_query: embed_query}}
    else
      {:error, Error.new(:invalid_embedding_model, "embed_query must be a one- or two-arity function")}
    end
  end

  def new(_embed_documents, _opts) do
    {:error, Error.new(:invalid_embedding_model, "embed_documents must be a one- or two-arity function")}
  end

  @spec new!(function(), keyword()) :: t()
  def new!(embed_documents, opts \\ []) do
    case new(embed_documents, opts) do
      {:ok, model} -> model
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @impl true
  def embed_documents(%__MODULE__{embed_documents: fun}, documents, opts) do
    call_embedding_fun(fun, documents, opts)
  end

  @impl true
  def embed_query(%__MODULE__{embed_query: fun}, query, opts) when is_function(fun) do
    call_embedding_fun(fun, query, opts)
  end

  def embed_query(%__MODULE__{} = model, query, opts) do
    case embed_documents(model, [query], opts) do
      {:ok, [vector | _rest]} ->
        {:ok, vector}

      {:ok, []} ->
        {:error, Error.new(:invalid_embedding, "embedding function returned no query vector")}

      {:error, _error} = error ->
        error
    end
  end

  defp call_embedding_fun(fun, input, opts) when is_function(fun, 2),
    do: normalize_result(fun.(input, opts))

  defp call_embedding_fun(fun, input, _opts) when is_function(fun, 1),
    do: normalize_result(fun.(input))

  defp normalize_result({:ok, value}), do: {:ok, value}
  defp normalize_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_result({:error, reason}),
    do: {:error, Error.new(:embedding_error, inspect(reason))}

  defp normalize_result(value), do: {:ok, value}
end
