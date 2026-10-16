defmodule BeamWeaver.Checkpoint.Ecto.Maintenance do
  @moduledoc false

  import Ecto.Query

  alias BeamWeaver.Checkpoint.DeltaCompaction
  alias BeamWeaver.Checkpoint.Ecto, as: EctoSaver
  alias BeamWeaver.Checkpoint.Ecto.Listing
  alias BeamWeaver.Checkpoint.Ecto.Query

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
    Query.transaction(saver, fn -> do_prune(saver, thread_ids, opts) end)
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

  defp do_delete_for_runs(saver, run_ids) do
    if Listing.queryable_metadata?(saver),
      do: delete_for_runs_in_sql(saver, run_ids),
      else: delete_for_runs_decoded(saver, run_ids)
  end

  defp delete_for_runs_in_sql(saver, run_ids) do
    matching_checkpoint =
      from(checkpoint in Query.checkpoints(saver),
        where:
          checkpoint.thread_id == parent_as(:write).thread_id and
            checkpoint.checkpoint_ns == parent_as(:write).checkpoint_ns and
            checkpoint.checkpoint_id == parent_as(:write).checkpoint_id and
            json_extract_path(checkpoint.metadata, ["run_id"]) in ^run_ids,
        select: 1
      )

    writes =
      from(write in Query.writes(saver),
        as: :write,
        where: exists(subquery(matching_checkpoint))
      )

    checkpoints =
      from(checkpoint in Query.checkpoints(saver),
        where: json_extract_path(checkpoint.metadata, ["run_id"]) in ^run_ids
      )

    with {:ok, _result} <- Query.delete_all(saver, writes),
         {:ok, _result} <- Query.delete_all(saver, checkpoints) do
      :ok
    end
  end

  # The codec stores metadata that SQL can't read, so every checkpoint's
  # metadata is decoded to find the runs.
  defp delete_for_runs_decoded(saver, run_ids) do
    run_ids = MapSet.new(run_ids)

    query =
      from(checkpoint in Query.checkpoints(saver),
        select: {checkpoint.thread_id, checkpoint.checkpoint_ns, checkpoint.checkpoint_id, checkpoint.metadata}
      )

    with {:ok, rows} <- Query.all(saver, query),
         {:ok, keys} <- run_checkpoint_keys(saver, rows, run_ids) do
      keys
      |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
      |> Enum.reduce_while(:ok, fn {thread_id, checkpoints}, :ok ->
        case delete_checkpoints(saver, thread_id, checkpoints) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp run_checkpoint_keys(saver, rows, run_ids) do
    Enum.reduce_while(rows, {:ok, []}, fn {thread_id, namespace, checkpoint_id, metadata}, {:ok, keys} ->
      case EctoSaver.load_json_value(saver, metadata || %{}) do
        {:ok, %{"run_id" => run_id}} ->
          if MapSet.member?(run_ids, run_id),
            do: {:cont, {:ok, [{thread_id, namespace, checkpoint_id} | keys]}},
            else: {:cont, {:ok, keys}}

        {:ok, _metadata} ->
          {:cont, {:ok, keys}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
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

  defp do_prune(saver, thread_ids, opts) do
    strategy = Keyword.get(opts, :strategy, :keep_latest)

    Enum.reduce_while(thread_ids, :ok, fn thread_id, :ok ->
      result =
        if strategy in [:delete, "delete"],
          do: do_delete_thread(saver, thread_id),
          else: prune_keep_latest(saver, thread_id)

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp prune_keep_latest(saver, thread_id) do
    config = %{"configurable" => %{"thread_id" => thread_id}}

    with {:ok, records} <- Listing.list_result(saver, config, []) do
      removals =
        records
        |> Enum.group_by(& &1.config["configurable"]["checkpoint_ns"])
        |> Enum.flat_map(fn {_namespace, records} ->
          keep = records |> DeltaCompaction.keep_ids() |> MapSet.new()
          Enum.reject(records, &MapSet.member?(keep, &1.checkpoint["id"]))
        end)

      delete_records(saver, thread_id, removals)
    end
  end

  defp delete_records(saver, thread_id, records) do
    checkpoints =
      Enum.map(records, &{&1.config["configurable"]["checkpoint_ns"], &1.config["configurable"]["checkpoint_id"]})

    delete_checkpoints(saver, thread_id, checkpoints)
  end

  # Deletes the given `{checkpoint_ns, checkpoint_id}` checkpoints of one
  # thread and their writes.
  defp delete_checkpoints(_saver, _thread_id, []), do: :ok

  defp delete_checkpoints(saver, thread_id, checkpoints) do
    condition =
      checkpoints
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.reduce(dynamic(false), fn {namespace, checkpoint_ids}, condition ->
        dynamic(
          [row],
          ^condition or
            (row.checkpoint_ns == ^namespace and row.checkpoint_id in ^checkpoint_ids)
        )
      end)

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
end
