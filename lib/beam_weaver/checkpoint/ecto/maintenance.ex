defmodule BeamWeaver.Checkpoint.Ecto.Maintenance do
  @moduledoc false

  alias BeamWeaver.Checkpoint.DeltaCompaction
  alias BeamWeaver.Checkpoint.Ecto.Listing
  alias BeamWeaver.Checkpoint.Ecto.SQL

  def delete_thread(saver, thread_id) do
    with {:ok, _} <-
           SQL.query(saver, "DELETE FROM #{saver.writes_table} WHERE thread_id = $1", [thread_id]),
         {:ok, _} <-
           SQL.query(saver, "DELETE FROM #{saver.checkpoints_table} WHERE thread_id = $1", [
             thread_id
           ]) do
      :ok
    end
  end

  def delete_for_runs(_saver, []), do: :ok

  def delete_for_runs(saver, run_ids) when is_list(run_ids) do
    SQL.transaction(saver, fn -> do_delete_for_runs(saver, run_ids) end)
  end

  def copy_thread(saver, source_thread_id, target_thread_id) do
    SQL.transaction(saver, fn -> do_copy_thread(saver, source_thread_id, target_thread_id) end)
  end

  def prune(saver, thread_ids, opts) do
    SQL.transaction(saver, fn -> do_prune(saver, thread_ids, opts) end)
  end

  defp do_delete_for_runs(saver, run_ids) do
    checkpoint_sql = """
    SELECT thread_id, checkpoint_ns, checkpoint_id
    FROM #{saver.checkpoints_table}
    WHERE metadata->>'run_id' = ANY($1)
    """

    with {:ok, %{rows: rows}} <- SQL.query(saver, checkpoint_sql, [run_ids]) do
      Enum.reduce_while(rows, :ok, fn [thread_id, namespace, checkpoint_id], :ok ->
        with {:ok, _} <-
               SQL.query(
                 saver,
                 "DELETE FROM #{saver.writes_table} WHERE thread_id = $1 AND checkpoint_ns = $2 AND checkpoint_id = $3",
                 [thread_id, namespace, checkpoint_id]
               ),
             {:ok, _} <-
               SQL.query(
                 saver,
                 "DELETE FROM #{saver.checkpoints_table} WHERE thread_id = $1 AND checkpoint_ns = $2 AND checkpoint_id = $3",
                 [thread_id, namespace, checkpoint_id]
               ) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp do_copy_thread(saver, source_thread_id, target_thread_id) do
    checkpoint_sql = """
    INSERT INTO #{saver.checkpoints_table}
      (thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata)
    SELECT $2, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata
    FROM #{saver.checkpoints_table}
    WHERE thread_id = $1
    ON CONFLICT DO NOTHING
    """

    writes_sql = """
    INSERT INTO #{saver.writes_table}
      (thread_id, checkpoint_ns, checkpoint_id, task_id, write_index, channel, value, task_path)
    SELECT $2, checkpoint_ns, checkpoint_id, task_id, write_index, channel, value, task_path
    FROM #{saver.writes_table}
    WHERE thread_id = $1
    ON CONFLICT DO NOTHING
    """

    with {:ok, _} <- SQL.query(saver, checkpoint_sql, [source_thread_id, target_thread_id]),
         {:ok, _} <- SQL.query(saver, writes_sql, [source_thread_id, target_thread_id]) do
      :ok
    end
  end

  defp do_prune(saver, thread_ids, opts) do
    strategy = Keyword.get(opts, :strategy, :keep_latest)

    Enum.reduce_while(thread_ids, :ok, fn thread_id, :ok ->
      result =
        case strategy do
          :delete -> delete_thread(saver, thread_id)
          "delete" -> delete_thread(saver, thread_id)
          _keep_latest -> prune_keep_latest(saver, thread_id)
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp prune_keep_latest(saver, thread_id) do
    saver
    |> Listing.list(%{"configurable" => %{"thread_id" => thread_id}}, [])
    |> Enum.group_by(fn tuple -> tuple.config["configurable"]["checkpoint_ns"] end)
    |> Enum.flat_map(fn {_namespace, records} ->
      keep = DeltaCompaction.keep_ids(records)
      Enum.reject(records, &(&1.checkpoint["id"] in keep))
    end)
    |> Enum.reduce_while(:ok, fn record, :ok ->
      configurable = record.config["configurable"]
      thread_id = configurable["thread_id"]
      namespace = configurable["checkpoint_ns"]
      checkpoint_id = configurable["checkpoint_id"]

      with {:ok, _} <-
             SQL.query(
               saver,
               "DELETE FROM #{saver.writes_table} WHERE thread_id = $1 AND checkpoint_ns = $2 AND checkpoint_id = $3",
               [thread_id, namespace, checkpoint_id]
             ),
           {:ok, _} <-
             SQL.query(
               saver,
               "DELETE FROM #{saver.checkpoints_table} WHERE thread_id = $1 AND checkpoint_ns = $2 AND checkpoint_id = $3",
               [thread_id, namespace, checkpoint_id]
             ) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end
end
