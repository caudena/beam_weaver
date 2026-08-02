defmodule BeamWeaver.Adapters.EctoPostgresTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Adapters.EctoPostgres
  alias BeamWeaver.Core.Error

  defmodule Repo do
    def transact(fun) when is_function(fun, 0) do
      send(self(), {__MODULE__, :transact})

      case fun.() do
        {:ok, _result} = result -> result
        {:error, _reason} = error -> error
      end
    end

    def transaction(_fun) do
      send(self(), {__MODULE__, :transaction})
      raise "deprecated transaction/1 was called"
    end
  end

  test "uses Repo.transact/1 and preserves successful result shapes" do
    assert :ok = EctoPostgres.transaction(Repo, fn -> :ok end)
    assert {:ok, :value} = EctoPostgres.transaction(Repo, fn -> {:ok, :value} end)
    assert :value = EctoPostgres.transaction(Repo, fn -> :value end)

    assert_received {Repo, :transact}
    refute_received {Repo, :transaction}
  end

  test "preserves BeamWeaver errors and normalizes other rollback reasons" do
    error = Error.new(:expected, "expected")

    assert {:error, ^error} = EctoPostgres.transaction(Repo, fn -> {:error, error} end)

    assert {:error, %Error{type: :ecto_postgres_error, details: %{error: ":db_down"}}} =
             EctoPostgres.transaction(Repo, fn -> {:error, :db_down} end)
  end
end
