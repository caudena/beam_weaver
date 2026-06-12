defmodule BeamWeaver.Checkpoint.Ecto.Rows do
  @moduledoc false

  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Ecto.SQL
  alias BeamWeaver.Checkpoint.PendingWrite

  def tuple_from_row(saver, row) do
    saver
    |> tuples_from_rows([row])
    |> List.first()
  end

  def tuples_from_rows(_saver, []), do: []

  def tuples_from_rows(saver, rows) do
    {rows, embedded_write_rows} = split_rows(rows)
    tuples = Enum.map(rows, &base_tuple_from_row(saver, &1))

    pending_by_key =
      if embedded_write_rows do
        pending_writes_from_rows(saver, embedded_write_rows)
      else
        pending_writes_by_key(saver, write_keys(tuples))
      end

    Enum.map(tuples, fn tuple ->
      pending = Map.get(pending_by_key, tuple_key(tuple), empty_pending())
      parent_pending = Map.get(pending_by_key, parent_key(tuple), empty_pending())

      tuple
      |> Map.put(:pending_write_records, pending.records)
      |> Map.put(:pending_writes, pending.writes)
      |> Map.put(:pending_write_paths, pending.paths)
      |> maybe_put_parent_pending_writes(parent_pending.writes)
    end)
  end

  defp base_tuple_from_row(saver, [
         thread_id,
         namespace,
         checkpoint_id,
         parent_id,
         checkpoint,
         metadata
       ]) do
    checkpoint = saver.__struct__.load_json_value!(saver, checkpoint || %{})
    metadata = saver.__struct__.load_json_value!(saver, metadata || %{})

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

    %{
      config: config,
      checkpoint: checkpoint,
      metadata: metadata || %{},
      parent_config: parent_config
    }
  end

  defp split_rows(rows) do
    Enum.reduce(rows, {[], [], true}, fn
      [
        thread_id,
        namespace,
        checkpoint_id,
        parent_id,
        checkpoint,
        metadata,
        write_rows
      ],
      {rows, write_acc, true}
      when is_list(write_rows) ->
        {
          [[thread_id, namespace, checkpoint_id, parent_id, checkpoint, metadata] | rows],
          Enum.reverse(write_rows) ++ write_acc,
          true
        }

      row, {rows, _write_acc, _embedded?} ->
        {[row | rows], [], false}
    end)
    |> case do
      {rows, write_rows, true} -> {Enum.reverse(rows), Enum.reverse(write_rows)}
      {rows, _write_rows, false} -> {Enum.reverse(rows), nil}
    end
  end

  def pending_writes(saver, thread_id, namespace, checkpoint_id) do
    saver
    |> pending_writes_by_key([{thread_id, namespace, checkpoint_id}])
    |> Map.get({thread_id, namespace, checkpoint_id}, empty_pending())
  end

  defp pending_writes_by_key(_saver, []), do: %{}

  defp pending_writes_by_key(saver, keys) do
    keys = Enum.uniq(keys)

    sql = """
    WITH requested(thread_id, checkpoint_ns, checkpoint_id) AS (
      SELECT *
      FROM unnest($1::text[], $2::text[], $3::text[])
    )
    SELECT writes.thread_id, writes.checkpoint_ns, writes.checkpoint_id,
           writes.task_id, writes.write_index, writes.channel, writes.value, writes.task_path
    FROM #{saver.writes_table} AS writes
    JOIN requested
      ON writes.thread_id = requested.thread_id
     AND writes.checkpoint_ns = requested.checkpoint_ns
     AND writes.checkpoint_id = requested.checkpoint_id
    ORDER BY writes.thread_id ASC, writes.checkpoint_ns ASC, writes.checkpoint_id ASC,
             writes.task_id ASC, writes.write_index ASC
    """

    {thread_ids, namespaces, checkpoint_ids} =
      Enum.reduce(keys, {[], [], []}, fn {thread_id, namespace, checkpoint_id}, {threads, namespaces, checkpoints} ->
        {[thread_id | threads], [namespace | namespaces], [checkpoint_id | checkpoints]}
      end)

    params = [Enum.reverse(thread_ids), Enum.reverse(namespaces), Enum.reverse(checkpoint_ids)]

    case SQL.query(saver, sql, params) do
      {:ok, %{rows: rows}} ->
        pending_writes_from_rows(saver, rows)

      _error ->
        %{}
    end
  end

  defp pending_writes_from_rows(saver, rows) do
    rows
    |> unique_write_rows()
    |> Enum.group_by(fn [thread_id, namespace, checkpoint_id | _rest] ->
      {thread_id, namespace, checkpoint_id}
    end)
    |> Map.new(fn {key, rows} -> {key, pending_from_rows(saver, key, rows)} end)
  end

  defp pending_from_rows(saver, {thread_id, namespace, checkpoint_id}, rows) do
    records =
      Enum.map(rows, fn [_thread_id, _namespace, _checkpoint_id, task_id, index, channel, value, path] ->
        %PendingWrite{
          thread_id: thread_id,
          checkpoint_ns: namespace,
          checkpoint_id: checkpoint_id,
          task_id: task_id,
          index: index,
          channel: channel,
          value: saver.__struct__.load_json_value!(saver, value),
          path: path || ""
        }
      end)

    %{
      records: records,
      writes: Enum.map(records, &PendingWrite.tuple/1),
      paths: Enum.map(records, &PendingWrite.path_tuple/1)
    }
  end

  defp unique_write_rows(rows) do
    rows
    |> Enum.reduce({MapSet.new(), []}, fn row, {seen, acc} ->
      key = write_row_key(row)

      if MapSet.member?(seen, key) do
        {seen, acc}
      else
        {MapSet.put(seen, key), [row | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp write_row_key([thread_id, namespace, checkpoint_id, task_id, index | _rest]),
    do: {thread_id, namespace, checkpoint_id, task_id, index}

  defp write_keys(tuples) do
    tuples
    |> Enum.flat_map(fn tuple -> [tuple_key(tuple), parent_key(tuple)] end)
    |> Enum.reject(&is_nil/1)
  end

  defp tuple_key(tuple) do
    configurable = tuple.config["configurable"]
    {configurable["thread_id"], configurable["checkpoint_ns"], configurable["checkpoint_id"]}
  end

  defp parent_key(%{parent_config: %{} = parent_config}) do
    configurable = parent_config["configurable"]
    {configurable["thread_id"], configurable["checkpoint_ns"], configurable["checkpoint_id"]}
  end

  defp parent_key(_tuple), do: nil

  defp maybe_put_parent_pending_writes(tuple, _writes) when is_nil(tuple.parent_config), do: tuple
  defp maybe_put_parent_pending_writes(tuple, writes), do: Map.put(tuple, :parent_pending_writes, writes)

  defp empty_pending, do: %{records: [], writes: [], paths: []}
end
