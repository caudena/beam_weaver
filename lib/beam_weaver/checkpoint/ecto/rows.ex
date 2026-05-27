defmodule BeamWeaver.Checkpoint.Ecto.Rows do
  @moduledoc false

  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Ecto.SQL
  alias BeamWeaver.Checkpoint.PendingWrite

  def tuple_from_row(saver, [
        thread_id,
        namespace,
        checkpoint_id,
        parent_id,
        checkpoint,
        metadata
      ]) do
    checkpoint_map =
      checkpoint
      |> Map.get("checkpoint_map", %{})
      |> Config.normalize_checkpoint_map()
      |> Map.put(namespace, checkpoint_id)

    target = Map.get(checkpoint, "checkpoint_target_ns")

    config =
      %{
        "configurable" => %{
          "thread_id" => thread_id,
          "checkpoint_ns" => namespace,
          "checkpoint_id" => checkpoint_id,
          "checkpoint_map" => checkpoint_map
        }
      }
      |> Config.put_target_namespace(%{"checkpoint_target_ns" => target})

    parent_config =
      if parent_id do
        %{
          "configurable" => %{
            "thread_id" => thread_id,
            "checkpoint_ns" => namespace,
            "checkpoint_id" => parent_id,
            "checkpoint_map" => Map.put(checkpoint_map, namespace, parent_id)
          }
        }
        |> Config.put_target_namespace(%{"checkpoint_target_ns" => target})
      end

    pending = pending_writes(saver, thread_id, namespace, checkpoint_id)

    %{
      config: config,
      checkpoint: checkpoint,
      metadata: metadata || %{},
      parent_config: parent_config,
      pending_write_records: pending.records,
      pending_writes: pending.writes,
      pending_write_paths: pending.paths
    }
  end

  def pending_writes(saver, thread_id, namespace, checkpoint_id) do
    sql = """
    SELECT task_id, channel, value, task_path
    FROM #{saver.writes_table}
    WHERE thread_id = $1 AND checkpoint_ns = $2 AND checkpoint_id = $3
    ORDER BY task_id ASC, write_index ASC
    """

    case SQL.query(saver, sql, [thread_id, namespace, checkpoint_id]) do
      {:ok, %{rows: rows}} ->
        records =
          Enum.with_index(rows, fn [task_id, channel, value, path], index ->
            %PendingWrite{
              thread_id: thread_id,
              checkpoint_ns: namespace,
              checkpoint_id: checkpoint_id,
              task_id: task_id,
              index: index,
              channel: channel,
              value: value,
              path: path || ""
            }
          end)

        %{
          records: records,
          writes: Enum.map(records, &PendingWrite.tuple/1),
          paths: Enum.map(records, &PendingWrite.path_tuple/1)
        }

      _error ->
        %{records: [], writes: [], paths: []}
    end
  end
end
