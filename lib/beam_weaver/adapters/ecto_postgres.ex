defmodule BeamWeaver.Adapters.EctoPostgres do
  @moduledoc """
  Shared helpers for BeamWeaver Ecto/Postgres adapters.
  """

  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Core.Error

  @spec transaction(module(), (-> term())) :: term() | {:error, Error.t()}
  def transaction(repo, fun) when is_function(fun, 0) do
    if is_atom(repo) and function_exported?(repo, :transaction, 1) do
      case repo.transaction(fn ->
             case fun.() do
               {:error, reason} -> repo.rollback(reason)
               other -> other
             end
           end) do
        {:ok, :ok} -> :ok
        {:ok, {:error, %Error{} = error}} -> {:error, error}
        {:ok, {:error, reason}} -> {:error, normalize_error(reason)}
        {:ok, other} -> other
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> {:error, normalize_error(reason)}
      end
    else
      fun.()
    end
  rescue
    exception -> {:error, normalize_error(exception)}
  end

  defp normalize_error(%Error{} = error), do: error

  defp normalize_error(error) do
    AdapterError.normalize(error, :ecto_postgres_error, "Ecto/Postgres adapter error")
  end
end
