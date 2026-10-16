defmodule BeamWeaver.Graph.Execution.Replay do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.DeltaReplay
  alias BeamWeaver.Graph.Execution.Scheduler
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Graph.Execution.TaskRequest

  # The state also holds what is known of the checkpoint it was read from
  # (`:known_checkpoint`), so writing the run's first checkpoint after it
  # doesn't read it again.
  @spec restore_checkpoint_state(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def restore_checkpoint_state(%{checkpointer: nil}, _config), do: {:ok, empty_checkpoint_state()}

  def restore_checkpoint_state(%{checkpointer: checkpointer} = compiled, config) do
    config = SubgraphRouter.checkpoint_config(compiled, config)
    tuple = CheckpointIO.get_tuple(checkpointer, config)

    with {:ok, restored} <- restore_found_tuple(compiled, tuple) do
      {:ok, Map.put(restored, :known_checkpoint, CheckpointIO.known_checkpoint(config, tuple))}
    end
  end

  defp restore_found_tuple(_compiled, nil), do: {:ok, empty_checkpoint_state()}
  defp restore_found_tuple(compiled, tuple), do: restore_tuple(compiled, tuple)

  # A checkpoint's state as a run keeps it: every channel saved with the
  # thread, the graph's own bookkeeping included, under the graph's keys.
  @spec restore_tuple(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def restore_tuple(compiled, tuple) do
    restored = Execution.checkpoint_state(tuple)
    values = ChannelLookup.graph_keys(compiled.graph, restored.values)

    with {:ok, values} <- DeltaReplay.restore_channel_values(compiled, tuple, values) do
      {:ok, Map.merge(restored, %{values: values, checkpoint?: true})}
    end
  end

  @spec empty_checkpoint_state() :: map()
  def empty_checkpoint_state, do: Map.put(Execution.checkpoint_state(nil), :checkpoint?, false)

  @spec replay_pending?(map()) :: boolean()
  def replay_pending?(%{pending_writes: pending_writes, next: next}) do
    pending_writes != [] and (next != [] or pending_error_writes?(pending_writes))
  end

  # Continues the checkpoint that the config names, as when replaying an
  # earlier step: the input is empty and the config has a `checkpoint_id`.
  @spec continue_from_checkpoint?(map(), map(), map()) :: boolean()
  def continue_from_checkpoint?(config, input, _restored) when input == %{},
    do: checkpoint_id?(config)

  def continue_from_checkpoint?(_config, _input, _restored), do: false

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

  defp checkpoint_id?(config) do
    config
    |> Checkpoint.configurable()
    |> Map.get("checkpoint_id")
    |> is_binary()
  end

  @spec initial_ready(map(), map(), map(), boolean()) :: [TaskRequest.t()]
  def initial_ready(
        %{plan: %{entry_requests: [_first | _rest] = entries}},
        _config,
        _restored,
        false
      ),
      do: entries

  def initial_ready(compiled, _config, _restored, false) do
    Enum.map(compiled.graph.entry_points, fn node ->
      TaskRequest.pull(node, [Scheduler.branch_channel("__start__", node)])
    end)
  end

  def initial_ready(compiled, config, restored, true) do
    {error_ready, handled_error_task_ids} = pending_error_replay(compiled, restored)

    completed_task_ids =
      restored.pending_writes
      |> Execution.finished_task_ids()
      |> MapSet.new()
      |> MapSet.union(handled_error_task_ids)

    step = initial_step(restored, true)

    replay_ready =
      restored.next
      |> Enum.map(&TaskRequest.from_checkpoint/1)
      |> Enum.reject(fn ready_entry ->
        node = TaskRequest.name(ready_entry)

        ready_task_paths(ready_entry)
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

  @spec task_trigger_versions(map(), map(), boolean()) :: map()
  def task_trigger_versions(restored, _input_channel_versions, true),
    do: restored.channel_versions

  def task_trigger_versions(_restored, input_channel_versions, false), do: input_channel_versions

  @spec pending_interrupt_records(map(), map()) :: [map()]
  def pending_interrupt_records(%{checkpointer: nil}, _config), do: []

  def pending_interrupt_records(%{checkpointer: checkpointer}, config) do
    case CheckpointIO.get_tuple(checkpointer, config) do
      nil ->
        []

      tuple ->
        tuple
        |> Map.get(:pending_writes, [])
        |> Enum.flat_map(fn
          {task_id, "__interrupt__", interrupts} ->
            Enum.map(List.wrap(interrupts), &parent_interrupt_record(&1, task_id))

          _other ->
            []
        end)
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

  @spec checkpoint_next_records([term()], map() | nil) :: [map()]
  def checkpoint_next_records(next_ready, graph \\ nil)

  def checkpoint_next_records(next_ready, nil) do
    Enum.map(next_ready, &TaskRequest.checkpoint_record/1)
  end

  def checkpoint_next_records(next_ready, graph) do
    Enum.map(next_ready, &TaskRequest.checkpoint_record(&1, graph))
  end

  @spec ready_names([term()]) :: [String.t()]
  def ready_names(ready), do: Enum.map(ready, &TaskRequest.name/1)

  @spec ready_task_paths(term()) :: [term()]
  def ready_task_paths(ready), do: TaskRequest.task_paths(ready)

  defp pending_error_writes?(pending_writes) do
    Enum.any?(pending_writes, fn
      {_task_id, "__error__", _error} -> true
      {_task_id, "__error__", _error, _path} -> true
      _other -> false
    end)
  end

  defp pending_error_replay(compiled, %{pending_writes: writes, pending_write_paths: paths}) do
    path_by_task =
      Map.new(paths || [], fn
        {task_id, "__error__", path} -> {{task_id, "__error__"}, path}
        {task_id, channel, path} -> {{task_id, channel}, path}
      end)

    writes
    |> List.wrap()
    |> Enum.reduce({[], MapSet.new()}, fn
      {task_id, "__error__", error}, {requests, task_ids} ->
        replay_error = replay_error(error)

        node =
          node_from_path(path_by_task[{task_id, "__error__"}]) || node_from_error(replay_error)

        maybe_add_error_request(compiled, node, replay_error, task_id, requests, task_ids)

      {task_id, "__error__", error, path}, {requests, task_ids} ->
        replay_error = replay_error(error)

        node =
          node_from_path(path || path_by_task[{task_id, "__error__"}]) ||
            node_from_error(replay_error)

        maybe_add_error_request(compiled, node, replay_error, task_id, requests, task_ids)

      _other, acc ->
        acc
    end)
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
