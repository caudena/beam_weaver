defmodule BeamWeaver.Graph.Execution.Replay do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.DeltaReplay
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.MapAccess

  # The state also holds what is known of the checkpoint it was read from
  # (`:known_checkpoint`), so writing the run's first checkpoint after it
  # doesn't read it again.
  @spec restore_checkpoint_state(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def restore_checkpoint_state(%{checkpointer: nil}, _config), do: {:ok, empty_checkpoint_state()}

  def restore_checkpoint_state(%{checkpointer: checkpointer} = compiled, config) do
    config = SubgraphRouter.checkpoint_config(compiled, config)
    tuple = Checkpoint.get_tuple(checkpointer, config)

    with {:ok, restored} <- restore_found_tuple(compiled, tuple) do
      {:ok, Map.put(restored, :known_checkpoint, CheckpointIO.known_checkpoint(config, tuple))}
    end
  end

  defp restore_found_tuple(_compiled, nil), do: {:ok, empty_checkpoint_state()}
  defp restore_found_tuple(compiled, tuple), do: restore_tuple(compiled, tuple)

  # A checkpoint's state as a run keeps it: every channel saved with the
  # thread, the graph's own bookkeeping included, under the graph's keys. It
  # also holds the checkpoint's own config, what is known of it, and, for an
  # update made while its step was stopped, the channels written in that step
  # so far (`:step_channels`), which count as the step's writes when it
  # completes.
  @spec restore_tuple(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def restore_tuple(compiled, tuple) do
    restored = Execution.checkpoint_state(tuple)
    values = ChannelLookup.graph_keys(compiled.graph, restored.values)

    with {:ok, values} <- DeltaReplay.restore_channel_values(compiled, tuple, values) do
      {:ok,
       Map.merge(restored, %{
         values: values,
         checkpoint?: true,
         checkpoint_config: tuple.config,
         known_checkpoint: CheckpointIO.known_checkpoint(tuple.config, tuple),
         step_channels: step_channels(tuple.checkpoint, restored.step_start)
       })}
    end
  end

  defp step_channels(_checkpoint, nil), do: []

  defp step_channels(checkpoint, _step_start),
    do: Map.get(checkpoint, "updated_channels", Map.get(checkpoint, :updated_channels, []))

  @spec empty_checkpoint_state() :: map()
  def empty_checkpoint_state, do: Map.merge(Execution.checkpoint_state(nil), %{checkpoint?: false, step_channels: []})

  @spec replay_pending?(map()) :: boolean()
  def replay_pending?(%{pending_writes: pending_writes, next: next}) do
    pending_writes != [] and (next != [] or pending_error_writes?(pending_writes))
  end

  # Continues the checkpoint that the config names, as when replaying an
  # earlier step: the input is empty and the config has a `checkpoint_id`.
  @spec continue_from_checkpoint?(map(), map()) :: boolean()
  def continue_from_checkpoint?(config, input), do: input == %{} and checkpoint_id?(config)

  # Continues the thread's latest checkpoint instead of starting from the
  # entry points:
  #
  #   * on a resume with no new input, even when nothing is left to run (the
  #     run then returns the state);
  #   * when the checkpoint has steps that its last run didn't finish, because
  #     a crash or a breakpoint stopped it, and the run brings no new input or
  #     is a subgraph that its parent resumes (it gets the parent's state as
  #     input).
  @spec continue_latest_checkpoint?(map(), map(), boolean(), map()) :: boolean()
  def continue_latest_checkpoint?(config, input, resume_requested?, restored) do
    no_input? = input == %{}

    Map.get(restored, :checkpoint?, false) and not checkpoint_id?(config) and
      ((no_input? and resume_requested?) or
         (restored.next != [] and (no_input? or resume_requested?)))
  end

  defp checkpoint_id?(config), do: config |> Execution.checkpoint_id() |> is_binary()

  @spec initial_ready(map(), map(), map(), boolean()) :: [TaskRequest.t()]
  def initial_ready(compiled, _config, _restored, false), do: compiled.plan.entry_requests

  def initial_ready(compiled, config, restored, true) do
    {error_ready, handled_error_task_ids} = pending_error_replay(compiled, restored)

    completed_task_ids =
      restored.pending_writes
      |> Execution.finished_task_ids()
      |> MapSet.new()
      |> MapSet.union(handled_error_task_ids)

    step = initial_step(restored, true)

    replay_ready =
      Enum.reject(restored.next, fn ready_entry ->
        node = TaskRequest.name(ready_entry)

        ready_entry
        |> TaskRequest.task_paths()
        |> Enum.map(fn path ->
          Execution.task_id(
            compiled.name,
            config,
            step,
            node,
            path,
            restored.channel_versions
          )
        end)
        |> Enum.any?(&MapSet.member?(completed_task_ids, &1))
      end)

    # Every unfinished `Send` runs again, not one per node.
    Enum.uniq_by(error_ready ++ replay_ready, &TaskRequest.key/1)
  end

  @spec initial_step(map(), boolean()) :: non_neg_integer()
  def initial_step(_restored, false), do: 0
  def initial_step(restored, true), do: restored.step + 1

  # The ids that the ready tasks get when a step runs at `step` with
  # `trigger_versions`, computed the way the task planner computes them.
  @spec task_ids(map(), map(), integer(), map(), [term()]) :: [String.t()]
  def task_ids(compiled, config, step, trigger_versions, ready) do
    Enum.map(ready, fn entry ->
      Execution.task_id(
        compiled.name,
        config,
        step,
        TaskRequest.name(entry),
        TaskRequest.raw_path(entry),
        trigger_versions
      )
    end)
  end

  # The pending interrupts of the checkpoint `config` names, each with the id
  # of the task it pauses. A subgraph task that paused lists the subgraph's
  # own pauses (`subgraph?: true`): an answer to one of them goes to that
  # task, which hands it on to the subgraph by its id.
  @spec pending_interrupt_records(map(), map()) :: [map()]
  def pending_interrupt_records(%{checkpointer: nil}, _config), do: []

  def pending_interrupt_records(%{checkpointer: checkpointer}, config) do
    case Checkpoint.get_tuple(checkpointer, config) do
      nil ->
        []

      tuple ->
        tuple
        |> Map.get(:pending_writes, [])
        |> Enum.flat_map(fn
          {task_id, "__interrupt__", interrupts} ->
            interrupts |> List.wrap() |> Enum.flat_map(&task_interrupt_records(&1, task_id))

          _other ->
            []
        end)
    end
  end

  # The pauses that one task's interrupt stands for: a subgraph that paused
  # stands for every pause it lists in `interrupts`, at any depth.
  @spec task_interrupts(term()) :: [term()]
  def task_interrupts(interrupt) do
    case MapAccess.get(interrupt, :interrupts) do
      [_ | _] = nested -> Enum.flat_map(nested, &task_interrupts/1)
      _none -> [interrupt]
    end
  end

  defp task_interrupt_records(interrupt, task_id) do
    case task_interrupts(interrupt) do
      [^interrupt] ->
        [parent_interrupt_record(interrupt, task_id)]

      nested ->
        Enum.map(nested, &%{id: MapAccess.get(&1, :id), task_id: task_id, subgraph?: true})
    end
  end

  @spec checkpoint_task_records(list()) :: [map()]
  def checkpoint_task_records(task_events) do
    task_events
    |> Enum.flat_map(fn
      {:task, payload} ->
        [
          %{
            id: payload.task_id,
            kind: payload.kind,
            node: payload.node,
            step: payload.step,
            path: payload.path
          }
        ]

      _other ->
        []
    end)
  end

  @spec checkpoint_next_records([term()], map()) :: [map()]
  def checkpoint_next_records(next_ready, graph), do: Enum.map(next_ready, &TaskRequest.checkpoint_record(&1, graph))

  @spec ready_names([term()]) :: [String.t()]
  def ready_names(ready), do: Enum.map(ready, &TaskRequest.name/1)

  defp pending_error_writes?(pending_writes),
    do: Enum.any?(pending_writes, &(is_tuple(&1) and tuple_size(&1) in [3, 4] and elem(&1, 1) == "__error__"))

  defp pending_error_replay(compiled, %{pending_writes: writes, pending_write_paths: paths}) do
    path_by_task = Map.new(paths || [], fn {task_id, channel, path} -> {{task_id, channel}, path} end)

    for write when tuple_size(write) in [3, 4] and elem(write, 1) == "__error__" <- List.wrap(writes),
        reduce: {[], MapSet.new()} do
      {requests, task_ids} ->
        task_id = elem(write, 0)
        replay_error = replay_error(elem(write, 2))
        path = if tuple_size(write) == 4, do: elem(write, 3)
        node = node_from_path(path || path_by_task[{task_id, "__error__"}]) || node_from_error(replay_error)
        maybe_add_error_request(compiled, node, replay_error, task_id, requests, task_ids)
    end
  end

  defp pending_error_replay(_compiled, _restored), do: {[], MapSet.new()}

  defp maybe_add_error_request(_compiled, nil, _error, _task_id, requests, task_ids),
    do: {requests, task_ids}

  defp maybe_add_error_request(compiled, node, error, task_id, requests, task_ids) do
    if error_handler_node?(compiled, node) do
      {
        requests ++ [TaskRequest.error_handler(node, error, ["__error__"])],
        MapSet.put(task_ids, task_id)
      }
    else
      {requests, task_ids}
    end
  end

  defp error_handler_node?(compiled, node) do
    case compiled.graph.nodes[to_string(node)] do
      %{error_handler: handler} -> not is_nil(handler)
      _other -> false
    end
  end

  defp node_from_path(nil), do: nil
  defp node_from_path(""), do: nil

  defp node_from_path(path) when is_binary(path) do
    case BeamWeaver.JSON.decode(path) do
      {:ok, %{"node" => node}} when not is_nil(node) -> to_string(node)
      _other -> path
    end
  end

  defp node_from_path(_path), do: nil

  defp node_from_error(%{details: %{node: node}}) when not is_nil(node), do: to_string(node)
  defp node_from_error(%{details: %{"node" => node}}) when not is_nil(node), do: to_string(node)
  defp node_from_error(_error), do: nil

  defp replay_error(%{details: %{handled_error: handled_error}}), do: handled_error
  defp replay_error(%{details: %{"handled_error" => handled_error}}), do: handled_error
  defp replay_error(error), do: error

  defp parent_interrupt_record(%{id: _id} = interrupt, task_id),
    do: Map.put(interrupt, :task_id, task_id)

  # A subgraph that stopped at a breakpoint pauses its parent task with a
  # record that has no interrupt id.
  defp parent_interrupt_record(%{} = interrupt, task_id),
    do: interrupt |> Map.put_new(:id, nil) |> Map.put(:task_id, task_id)

  defp parent_interrupt_record(interrupt, _task_id), do: interrupt
end
