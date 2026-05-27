defmodule BeamWeaver.Adapter.Error do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @spec normalize(term(), atom(), String.t(), map() | keyword()) :: Error.t()
  def normalize(error, type, message, details \\ %{})

  def normalize(%Error{} = error, _type, _message, _details), do: error

  def normalize(error, type, message, details) do
    details =
      details
      |> Map.new()
      |> Map.put_new(:error, inspect(error))

    Error.new(type, message, details)
  end

  @spec query(map(), String.t(), list(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def query(%{repo: repo, query_module: query_module}, sql, params, opts \\ []) do
    type = Keyword.get(opts, :type, :adapter_error)
    message = Keyword.get(opts, :message, "adapter error")
    details = Keyword.get(opts, :details, %{})

    try do
      case query_module.query(repo, sql, params) do
        {:error, error} -> {:error, normalize(error, type, message, details)}
        result -> result
      end
    rescue
      exception -> {:error, normalize(exception, type, message, details)}
    end
  end
end
