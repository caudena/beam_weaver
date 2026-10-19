defmodule BeamWeaver.Checkpoint.Ecto.Maintenance do
  @moduledoc false

  import Ecto.Query

  alias BeamWeaver.Checkpoint.DeltaCompaction
  alias BeamWeaver.Checkpoint.Ecto, as: EctoSaver
  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Ecto.Listing
  alias BeamWeaver.Checkpoint.Ecto.Query
  alias BeamWeaver.Result

  def delete_thread(saver, thread_id) do
    Query.transaction(saver, fn -> do_delete_thread(saver, thread_id) end)
  end

  def delete_for_runs(_saver, []), do: :ok

  def delete_for_runs(saver, run_ids) when is_list(run_ids) do
    Query.transaction(saver, fn -> do_delete_for_runs(saver, run_ids) end)
  end

  def copy_thread(saver, source_thread_id, target_thread_id) do
    Query.transaction(saver, fn -> do_copy_thread(saver, source_thread_id, target_thread_id) end)
  end

  def prune(saver, thread_ids, opts) do
    with {:ok, strategy} <- DeltaCompaction.strategy(opts),
         do: Query.transaction(saver, fn -> do_prune(saver, thread_ids, strategy) end)
  end

  defp do_delete_thread(saver, thread_id) do
    with {:ok, _result} <-
           Query.delete_all(
             saver,
             from(write in Query.writes(saver), where: write.thread_id == ^thread_id)
           ),
         {:ok, _result} <-
           Query.delete_all(
             saver,
             from(checkpoint in Query.checkpoints(saver), where: checkpoint.thread_id == ^thread_id)
           ) do
      :ok
    end
  end

  # Deleting the checkpoints of some runs can't take delta history that a
  # later checkpoint of the thread reads. A checkpoint left whose parent goes
  # becomes the first of its thread, as after `prune/3`.
  defp do_delete_for_runs(saver, run_ids) do
    with {:ok, keys} <- run_checkpoint_keys(saver, run_ids) do
      keys
      |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
      |> Enum.reduce_while(:ok, fn {thread_id, checkpoints}, :ok ->
        with {:ok, orphans} <- orphans_keeping_history(saver, thread_id, checkpoints),
             :ok <- delete_checkpoints(saver, thread_id, checkpoints),
             :ok <- clear_parents(saver, thread_id, orphans) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  # The `{thread_id, checkpoint_ns, checkpoint_id}` of the runs' checkpoints.
  # When the codec stores metadata that SQL can't read, every checkpoint's
  # metadata is decoded to find the runs.
  defp run_checkpoint_keys(saver, run_ids) do
    if Listing.queryable_metadata?(saver) do
      Query.all(
        saver,
        from(checkpoint in Query.checkpoints(saver),
          where: json_extract_path(checkpoint.metadata, ["run_id"]) in ^run_ids,
          select: {checkpoint.thread_id, checkpoint.checkpoint_ns, checkpoint.checkpoint_id}
        )
      )
    else
      run_ids = MapSet.new(run_ids)

      query =
        from(checkpoint in Query.checkpoints(saver),
          select: {checkpoint.thread_id, checkpoint.checkpoint_ns, checkpoint.checkpoint_id, checkpoint.metadata}
        )

      with {:ok, rows} <- Query.all(saver, query),
           do: Result.flat_traverse(rows, &run_checkpoint_key(saver, &1, run_ids))
    end
  end

  defp run_checkpoint_key(saver, {thread_id, namespace, checkpoint_id, metadata}, run_ids) do
    case EctoSaver.load_json_value(saver, metadata || %{}) do
      {:ok, %{"run_id" => run_id}} ->
        {:ok, if(MapSet.member?(run_ids, run_id), do: {thread_id, namespace, checkpoint_id})}

      {:ok, _metadata} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  end

  # The thread's checkpoints left whose parent goes. Only these can lose
  # delta history, so the thread's checkpoints are read in full only when
  # there are some.
  defp orphans_keeping_history(saver, thread_id, checkpoints) do
    removed = MapSet.new(checkpoints)

    query =
      from(checkpoint in Query.checkpoints(saver),
        where: checkpoint.thread_id == ^thread_id and not is_nil(checkpoint.parent_checkpoint_id),
        select: {checkpoint.checkpoint_ns, %{id: checkpoint.checkpoint_id, parent_id: checkpoint.parent_checkpoint_id}}
      )

    with {:ok, links} <- Query.all(saver, query) do
      case links |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)) |> DeltaCompaction.orphans(removed) do
        [] ->
          {:ok, []}

        orphans ->
          with {:ok, namespaces} <- compaction_records(saver, thread_id) do
            if DeltaCompaction.breaks_history?(namespaces, removed),
              do: {:error, DeltaCompaction.history_in_use(thread_id)},
              else: {:ok, orphans}
          end
      end
    end
  end

  defp do_copy_thread(saver, source_thread_id, target_thread_id) do
    checkpoints =
      from(checkpoint in Query.checkpoints(saver),
        where: checkpoint.thread_id == ^source_thread_id,
        select: %{
          thread_id: type(^target_thread_id, :string),
          checkpoint_ns: checkpoint.checkpoint_ns,
          checkpoint_id: checkpoint.checkpoint_id,
          parent_checkpoint_id: checkpoint.parent_checkpoint_id,
          checkpoint: checkpoint.checkpoint,
          metadata: checkpoint.metadata,
          commit_order: checkpoint.commit_order
        }
      )

    writes =
      from(write in Query.writes(saver),
        where: write.thread_id == ^source_thread_id,
        select: %{
          thread_id: type(^target_thread_id, :string),
          checkpoint_ns: write.checkpoint_ns,
          checkpoint_id: write.checkpoint_id,
          task_id: write.task_id,
          write_index: write.write_index,
          channel: write.channel,
          value: write.value,
          task_path: write.task_path
        }
      )

    with {:ok, _result} <-
           Query.insert_all(saver, Query.checkpoints(saver), checkpoints,
             on_conflict: :nothing,
             conflict_target: [:thread_id, :checkpoint_ns, :checkpoint_id]
           ),
         {:ok, _result} <-
           Query.insert_all(saver, Query.writes(saver), writes,
             on_conflict: :nothing,
             conflict_target: [
               :thread_id,
               :checkpoint_ns,
               :checkpoint_id,
               :task_id,
               :write_index
             ]
           ) do
      :ok
    end
  end

  defp do_prune(saver, thread_ids, strategy) do
    prune_thread = if strategy == :delete, do: &do_delete_thread/2, else: &prune_keep_latest/2

    Enum.reduce_while(thread_ids, :ok, fn thread_id, :ok ->
      case prune_thread.(saver, thread_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp prune_keep_latest(saver, thread_id) do
    with {:ok, namespaces} <- compaction_records(saver, thread_id) do
      {removals, roots} = DeltaCompaction.prune_plan(namespaces)
      with :ok <- delete_checkpoints(saver, thread_id, removals), do: clear_parents(saver, thread_id, roots)
    end
  end

  # What `DeltaCompaction` reads of a thread's checkpoints, by namespace:
  # the checkpoints without their pending writes, and the channels of those.
  defp compaction_records(saver, thread_id) do
    checkpoints =
      from(checkpoint in Query.checkpoints(saver),
        where: checkpoint.thread_id == ^thread_id,
        select: {
          checkpoint.checkpoint_ns,
          checkpoint.checkpoint_id,
          checkpoint.parent_checkpoint_id,
          checkpoint.commit_order,
          checkpoint.checkpoint,
          checkpoint.metadata
        }
      )

    writes =
      from(write in Query.writes(saver),
        where: write.thread_id == ^thread_id,
        distinct: true,
        select: {write.checkpoint_ns, write.checkpoint_id, write.channel}
      )

    with {:ok, rows} <- Query.all(saver, checkpoints),
         {:ok, write_rows} <- Query.all(saver, writes),
         pending = Enum.group_by(write_rows, &Tuple.delete_at(&1, 2), &elem(&1, 2)),
         {:ok, records} <- Result.traverse(rows, &compaction_record(saver, &1, pending)) do
      {:ok, Enum.group_by(records, &elem(&1, 0), &elem(&1, 1))}
    end
  end

  defp compaction_record(saver, {namespace, checkpoint_id, parent_id, commit_order, checkpoint, metadata}, pending) do
    with {:ok, checkpoint} <- EctoSaver.load_json_value(saver, checkpoint || %{}),
         {:ok, metadata} <- EctoSaver.load_json_value(saver, metadata || %{}) do
      {:ok,
       {namespace,
        %{
          id: checkpoint_id,
          parent_id: parent_id,
          commit_order: commit_order,
          checkpoint: checkpoint,
          metadata: metadata,
          pending_channels: pending |> Map.get({namespace, checkpoint_id}, []) |> MapSet.new(),
          root_id: checkpoint |> Map.get("checkpoint_map") |> Config.normalize_checkpoint_map() |> Map.get("")
        }}}
    end
  end

  defp clear_parents(_saver, _thread_id, []), do: :ok

  defp clear_parents(saver, thread_id, checkpoints) do
    query =
      from(checkpoint in Query.checkpoints(saver),
        where: checkpoint.thread_id == ^thread_id,
        where: ^checkpoints_condition(checkpoints)
      )

    with {:ok, _result} <- Query.update_all(saver, query, set: [parent_checkpoint_id: nil]), do: :ok
  end

  # Deletes the given `{checkpoint_ns, checkpoint_id}` checkpoints of one
  # thread and their writes.
  defp delete_checkpoints(_saver, _thread_id, []), do: :ok

  defp delete_checkpoints(saver, thread_id, checkpoints) do
    condition = checkpoints_condition(checkpoints)

    writes =
      from(write in Query.writes(saver),
        where: write.thread_id == ^thread_id,
        where: ^condition
      )

    checkpoints =
      from(checkpoint in Query.checkpoints(saver),
        where: checkpoint.thread_id == ^thread_id,
        where: ^condition
      )

    with {:ok, _result} <- Query.delete_all(saver, writes),
         {:ok, _result} <- Query.delete_all(saver, checkpoints) do
      :ok
    end
  end

  defp checkpoints_condition(checkpoints) do
    checkpoints
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce(dynamic(false), fn {namespace, checkpoint_ids}, condition ->
      dynamic(
        [row],
        ^condition or
          (row.checkpoint_ns == ^namespace and row.checkpoint_id in ^checkpoint_ids)
      )
    end)
  end
end
