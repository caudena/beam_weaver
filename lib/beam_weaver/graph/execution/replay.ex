defmodule BeamWeaver.Graph.Execution.Replay do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.DeltaReplay
  alias BeamWeaver.Graph.Execution.Scheduler
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Graph.Execution.TaskRequest

  @spec restore_checkpoint_state(map(), map()) :: {:ok, Execution.checkpoint_state()} | {:error, Error.t()}
  def restore_checkpoint_state(%{checkpointer: nil}, _config), do: {:ok, Execution.checkpoint_state(nil)}

  def restore_checkpoint_state(%{checkpointer: checkpointer} = compiled, config) do
    config = SubgraphRouter.checkpoint_config(compiled, config)

    case CheckpointIO.get_tuple(checkpointer, config) do
      nil ->
        {:ok, Execution.checkpoint_state(nil)}

      tuple ->
        restored = Execution.checkpoint_state(tuple)

        with {:ok, values} <- DeltaReplay.restore_channel_values(compiled, tuple, restored.values) do
          {:ok, %{restored | values: values}}
        end
    end
  end

  @spec replay_pending?(map()) :: boolean()
  def replay_pending?(%{pending_writes: pending_writes, next: next}) do
    pending_writes != [] and (next != [] or pending_error_writes?(pending_writes))
  end

  @spec continue_from_checkpoint?(map(), map(), map()) :: boolean()
  def continue_from_checkpoint?(config, input, _restored) when input == %{} do
    config
    |> Checkpoint.configurable()
    |> Map.get("checkpoint_id")
    |> is_binary()
  end

  def continue_from_checkpoint?(_config, _input, _restored), do: false

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
      |> Execution.pending_task_ids()
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

    error_ready
    |> Kernel.++(replay_ready)
    |> Enum.uniq_by(fn request ->
      {TaskRequest.kind(request), TaskRequest.name(request), TaskRequest.error(request)}
    end)
  end

  @spec initial_step(map(), boolean()) :: non_neg_integer()
  def initial_step(_restored, false), do: 0
  def initial_step(restored, true), do: restored.step + 1

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
    do: %{interrupt | task_id: task_id}

  defp parent_interrupt_record(interrupt, _task_id), do: interrupt
end
