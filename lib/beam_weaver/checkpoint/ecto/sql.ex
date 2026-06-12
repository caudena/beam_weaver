defmodule BeamWeaver.Checkpoint.Ecto.SQL do
  @moduledoc false

  alias BeamWeaver.Adapter.Error, as: AdapterError

  def query(saver, sql, params) do
    AdapterError.query(saver, sql, params,
      type: :checkpoint_error,
      message: "checkpoint adapter error"
    )
  end

  def transaction(saver, fun) do
    BeamWeaver.Adapters.EctoPostgres.transaction(saver.repo, fun)
  end

  def delete_shallow_history(%{shallow?: false}, _thread_id, _namespace), do: :ok

  def delete_shallow_history(saver, thread_id, namespace) do
    with {:ok, _} <-
           query(
             saver,
             "DELETE FROM #{saver.writes_table} WHERE thread_id = $1 AND checkpoint_ns = $2",
             [thread_id, namespace]
           ),
         {:ok, _} <-
           query(
             saver,
             "DELETE FROM #{saver.checkpoints_table} WHERE thread_id = $1 AND checkpoint_ns = $2",
             [thread_id, namespace]
           ) do
      :ok
    end
  end
end
