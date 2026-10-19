defmodule BeamWeaver.Adapter.Error do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @spec normalize(term(), atom(), String.t()) :: Error.t()
  def normalize(%Error{} = error, _type, _message), do: error
  def normalize(error, type, message), do: Error.new(type, message, %{error: inspect(error)})

  @spec query(map(), String.t(), list(), atom(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def query(%{repo: repo, query_module: query_module}, sql, params, type, message) do
    case query_module.query(repo, sql, params) do
      {:error, error} -> {:error, normalize(error, type, message)}
      result -> result
    end
  rescue
    exception -> {:error, normalize(exception, type, message)}
  end
end
