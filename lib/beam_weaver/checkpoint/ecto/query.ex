defmodule BeamWeaver.Checkpoint.Ecto.Query do
  @moduledoc false

  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Core.Error

  defmodule CheckpointRow do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "beam_weaver_checkpoints" do
      field(:thread_id, :string)
      field(:checkpoint_ns, :string)
      field(:checkpoint_id, :string)
      field(:parent_checkpoint_id, :string)
      field(:checkpoint, :map)
      field(:metadata, :map)
      field(:commit_order, :integer)
      field(:inserted_at, :utc_datetime_usec)
    end
  end

  defmodule WriteRow do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "beam_weaver_checkpoint_writes" do
      field(:thread_id, :string)
      field(:checkpoint_ns, :string)
      field(:checkpoint_id, :string)
      field(:task_id, :string)
      field(:write_index, :integer)
      field(:channel, :string)
      field(:value, :map)
      field(:task_path, :string)
      field(:inserted_at, :utc_datetime_usec)
    end
  end

  def checkpoints(saver), do: {saver.checkpoints_table, CheckpointRow}
  def writes(saver), do: {saver.writes_table, WriteRow}

  def all(saver, query), do: run(saver, &saver.repo.all(query, &1), [])
  def one(saver, query), do: run(saver, &saver.repo.one(query, &1), [])
  def delete_all(saver, query), do: run(saver, &saver.repo.delete_all(query, &1), [])

  def insert_all(saver, source, rows, opts \\ []) do
    run(saver, &saver.repo.insert_all(source, rows, Keyword.merge(opts, &1)), [])
  end

  def transaction(saver, fun) when is_function(fun, 0) do
    opts = if sqlite?(saver), do: [mode: :immediate], else: []

    case saver.repo.transact(
           fn ->
             case fun.() do
               {:error, reason} -> {:error, reason}
               result -> {:ok, {:beam_weaver_transaction, result}}
             end
           end,
           opts
         ) do
      {:ok, {:beam_weaver_transaction, result}} -> result
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, normalize(reason)}
    end
  rescue
    exception -> {:error, normalize(exception)}
  end

  def lock_owner(saver, thread_id, checkpoint_ns) when is_binary(thread_id) do
    cond do
      postgres?(saver) ->
        raw(
          saver,
          "SELECT pg_advisory_xact_lock(hashtextextended($1, hashtext($2)::bigint))",
          [thread_id, checkpoint_ns]
        )
        |> ok_result()

      sqlite?(saver) ->
        :ok

      true ->
        {:error,
         Error.new(
           :checkpoint_error,
           "unsupported Ecto checkpoint adapter",
           %{adapter: inspect(adapter(saver))}
         )}
    end
  end

  def lock_owner(_saver, _thread_id, _checkpoint_ns),
    do: {:error, Error.new(:invalid_checkpoint, "checkpoint config requires thread_id")}

  def postgres?(saver), do: adapter(saver) == Ecto.Adapters.Postgres
  def sqlite?(saver), do: adapter(saver) == Ecto.Adapters.SQLite3

  defp adapter(saver), do: saver.repo.__adapter__()

  defp raw(saver, sql, params) do
    AdapterError.query(saver, sql, params,
      type: :checkpoint_error,
      message: "checkpoint adapter error"
    )
  end

  defp ok_result({:ok, _result}), do: :ok
  defp ok_result({:error, _reason} = error), do: error

  defp run(_saver, fun, opts) do
    case fun.(opts) do
      {:error, %Error{} = error} -> {:error, error}
      result -> {:ok, result}
    end
  rescue
    exception -> {:error, normalize(exception)}
  end

  defp normalize(error) do
    AdapterError.normalize(error, :checkpoint_error, "checkpoint adapter error")
  end
end
