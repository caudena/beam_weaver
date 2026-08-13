defmodule BeamWeaver.Checkpoint.Ecto.Rows do
  @moduledoc false

  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.PendingWrite

  def tuple_from_rows(saver, rows) do
    saver
    |> tuples_from_rows(rows)
    |> List.first()
  end

  def tuples_from_rows(_saver, []), do: []

  def tuples_from_rows(saver, rows) do
    {checkpoint_rows, write_rows} = split_rows(rows)
    pending_by_key = pending_writes_from_rows(saver, write_rows)

    Enum.map(checkpoint_rows, fn row ->
      tuple = base_tuple_from_row(saver, row)
      pending = Map.get(pending_by_key, tuple_key(tuple), empty_pending())
      parent_pending = Map.get(pending_by_key, parent_key(tuple), empty_pending())

      tuple
      |> Map.put(:pending_write_records, pending.records)
      |> Map.put(:pending_writes, pending.writes)
      |> Map.put(:pending_write_paths, pending.paths)
      |> maybe_put_parent_pending_writes(parent_pending.writes)
    end)
  end

  defp split_rows(rows) do
    {order, checkpoints, writes} =
      Enum.reduce(rows, {[], %{}, []}, fn {checkpoint, write}, {order, checkpoints, writes} ->
        key = checkpoint_key(checkpoint)

        {order, checkpoints} =
          if Map.has_key?(checkpoints, key) do
            {order, checkpoints}
          else
            {[key | order], Map.put(checkpoints, key, checkpoint)}
          end

        writes = if write[:checkpoint_id], do: [write | writes], else: writes
        {order, checkpoints, writes}
      end)

    checkpoint_rows = order |> Enum.reverse() |> Enum.map(&Map.fetch!(checkpoints, &1))
    {checkpoint_rows, Enum.reverse(writes)}
  end

  defp base_tuple_from_row(saver, row) do
    checkpoint = saver.__struct__.load_json_value!(saver, row.checkpoint || %{})
    metadata = saver.__struct__.load_json_value!(saver, row.metadata || %{})

    checkpoint_map =
      checkpoint
      |> Map.get("checkpoint_map", %{})
      |> Config.normalize_checkpoint_map()
      |> Map.put(row.checkpoint_ns, row.checkpoint_id)

    target = Map.get(checkpoint, "checkpoint_target_ns")

    config =
      %{
        "configurable" => %{
          "thread_id" => row.thread_id,
          "checkpoint_ns" => row.checkpoint_ns,
          "checkpoint_id" => row.checkpoint_id,
          "checkpoint_map" => checkpoint_map
        }
      }
      |> Config.put_target_namespace(%{"checkpoint_target_ns" => target})

    parent_config =
      if row.parent_checkpoint_id do
        %{
          "configurable" => %{
            "thread_id" => row.thread_id,
            "checkpoint_ns" => row.checkpoint_ns,
            "checkpoint_id" => row.parent_checkpoint_id,
            "checkpoint_map" => Map.put(checkpoint_map, row.checkpoint_ns, row.parent_checkpoint_id)
          }
        }
        |> Config.put_target_namespace(%{"checkpoint_target_ns" => target})
      end

    %{
      config: config,
      checkpoint: checkpoint,
      metadata: metadata,
      parent_config: parent_config,
      commit_order: row.commit_order
    }
  end

  defp pending_writes_from_rows(saver, rows) do
    rows
    |> Enum.uniq_by(&write_key/1)
    |> Enum.group_by(&checkpoint_key/1)
    |> Map.new(fn {key, rows} -> {key, pending_from_rows(saver, key, rows)} end)
  end

  defp pending_from_rows(saver, {thread_id, namespace, checkpoint_id}, rows) do
    records =
      Enum.map(rows, fn row ->
        %PendingWrite{
          thread_id: thread_id,
          checkpoint_ns: namespace,
          checkpoint_id: checkpoint_id,
          task_id: row.task_id,
          index: row.write_index,
          channel: row.channel,
          value: saver.__struct__.load_json_value!(saver, Config.load_write_value(row.value)),
          path: row.task_path || ""
        }
      end)

    %{
      records: records,
      writes: Enum.map(records, &PendingWrite.tuple/1),
      paths: Enum.map(records, &PendingWrite.path_tuple/1)
    }
  end

  defp checkpoint_key(%{"thread_id" => thread_id} = row) do
    {thread_id, Map.get(row, "checkpoint_ns", ""), row["checkpoint_id"]}
  end

  defp checkpoint_key(row), do: {row.thread_id, row.checkpoint_ns, row.checkpoint_id}

  defp write_key(row) do
    {row.thread_id, row.checkpoint_ns, row.checkpoint_id, row.task_id, row.write_index}
  end

  defp tuple_key(tuple), do: checkpoint_key(tuple.config["configurable"])

  defp parent_key(%{parent_config: %{} = parent_config}),
    do: checkpoint_key(parent_config["configurable"])

  defp parent_key(_tuple), do: nil

  defp maybe_put_parent_pending_writes(tuple, _writes) when is_nil(tuple.parent_config), do: tuple
  defp maybe_put_parent_pending_writes(tuple, writes), do: Map.put(tuple, :parent_pending_writes, writes)

  defp empty_pending, do: %{records: [], writes: [], paths: []}
end
