defmodule BeamWeaver.Graph.Execution.StoppedStep do
  @moduledoc false

  # A thread whose last step stopped partway, paused or failed, stays that
  # way when it is updated: the update goes into that step. The new checkpoint
  # holds the state with the writes of the tasks that finished in the step,
  # plus the update, and the tasks still to run. It keeps the step's number
  # and channel versions, so those tasks keep their ids: the next resume
  # answers their pauses, and a paused subgraph continues from its own
  # checkpoints, which its task's id names. Their pauses and errors move
  # along, as do the routes of the finished tasks, so the step still routes
  # from those when it completes. The checkpoint names the one the step
  # started from, whose state a resumed subgraph's update is measured against.
  #
  # An update made as a node is that node's result in the step: the node's
  # tasks still to run finish with it, or, when the node already finished, it
  # routes with the update as its output; any other node is routed from too.
  # The node arrives at its joins. When no task is left to run, the step
  # completes now.

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Execution.Route
  alias BeamWeaver.Graph.Execution.Scheduler
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.StateGraph

  @moved_channels ["__interrupt__", "__error__", "__route__"]

  # Saves `update` into the stopped step of `restored`, the checkpoint that
  # `config` names, as `as_node`'s result when it is given, with the tasks of
  # a `Command`'s `goto` among those still to run, and returns the new
  # checkpoint's config.
  @spec save(map(), map(), map(), ChannelMerge.state_update(), atom() | String.t() | nil, term()) ::
          {:ok, map()} | {:error, Error.t()}
  def save(compiled, config, restored, update, as_node, goto) do
    graph = compiled.graph
    node = if is_nil(as_node), do: nil, else: to_string(as_node)

    ready =
      compiled
      |> Replay.initial_ready(config, restored, true)
      |> Enum.reject(&(TaskRequest.name(&1) == node))
      |> CommandRouter.add_command_goto_tasks(goto)

    with {:ok, state} <- ChannelMerge.apply_pending_writes(restored.values, restored.pending_writes, graph),
         {:ok, values, updated} <- ChannelMerge.merge_state_update(state, update, graph),
         arrivals = if(node, do: StateGraph.join_writes(graph, node), else: []),
         {:ok, _arrivals, updated} <- ChannelMerge.merge_step_updates(updated, arrivals, graph) do
      writes =
        restored
        |> CheckpointIO.pending_writes_on(@moved_channels)
        |> put_node_result(compiled, config, restored, node, values)

      if ready == [],
        do: complete(compiled, config, restored, {updated, values, writes}, as_node),
        else: keep(compiled, config, restored, {updated, values, writes}, ready, as_node)
    end
  end

  # The channels written so far in the stopped step: by the tasks that
  # finished in it, and by updates made while it was stopped.
  @spec channels(map()) :: [String.t()]
  def channels(restored), do: Execution.pending_channels(restored.pending_writes) ++ restored.step_channels

  defp keep(compiled, config, restored, {updated, values, writes}, ready, as_node) do
    metadata = %{
      source: "update",
      step: restored.step,
      as_node: as_node,
      next: Replay.ready_names(ready),
      next_tasks: Replay.checkpoint_next_records(ready, compiled.graph),
      tasks: [],
      interrupts: [],
      channel_versions: restored.channel_versions,
      versions_seen: restored.versions_seen,
      updated_channels: Execution.normalize_channels(Execution.updated_channels(values) ++ channels(restored)),
      step_update: values,
      step_start: restored.step_start || Execution.checkpoint_id(config)
    }

    with {:ok, updated_config, _known} <-
           CheckpointIO.write_checkpoint(compiled, config, updated, metadata, restored.known_checkpoint),
         :ok <- CheckpointIO.put_task_writes(compiled.checkpointer, updated_config, writes) do
      {:ok, updated_config}
    end
  end

  # Every task of the stopped step has its result: the step routes from all
  # of them, and the update's checkpoint is the one the step ends with.
  defp complete(compiled, config, restored, {updated, values, writes}, as_node) do
    graph = compiled.graph
    routes = Route.from_writes(writes)

    with {:ok, schedule} <-
           Scheduler.prepare_next_tasks(compiled.plan, routes, Route.put_outputs(updated, routes, graph)),
         {:ok, schedule_step_update, scheduled} <-
           ChannelMerge.merge_step_updates(updated, schedule.updates, graph) do
      {joins, scheduled} = ChannelMerge.fire_joins(%{}, scheduled, graph)

      step_update =
        values
        |> Map.merge(Scheduler.hide_node_outputs(schedule_step_update))
        |> Map.merge(joins)

      updated_channels =
        (Execution.updated_channels(step_update) ++ schedule.channels ++ channels(restored))
        |> Execution.normalize_channels()
        |> Enum.reject(&Scheduler.node_outputs_channel?/1)

      next = Scheduler.add_channel_tasks(compiled.plan, schedule.ready, updated_channels)

      metadata = %{
        source: "update",
        step: Replay.initial_step(restored, true),
        as_node: as_node,
        next: Replay.ready_names(next),
        next_tasks: Replay.checkpoint_next_records(next, graph),
        tasks: [],
        interrupts: [],
        channel_versions:
          Execution.next_channel_versions(compiled.checkpointer, restored.channel_versions, updated_channels, graph),
        versions_seen:
          Execution.mark_versions_seen(restored.versions_seen, Enum.map(routes, & &1.node), restored.channel_versions),
        updated_channels: updated_channels,
        step_update: step_update
      }

      with {:ok, updated_config, _known} <-
             CheckpointIO.write_checkpoint(compiled, config, scheduled, metadata, restored.known_checkpoint),
           do: {:ok, updated_config}
    end
  end

  # Puts the update in the stopped step as `node`'s result, among the step's
  # writes that move to the new checkpoint (`{task_id, channel, value, path}`).
  defp put_node_result(writes, _compiled, _config, _restored, nil, _values), do: writes

  defp put_node_result(writes, compiled, config, restored, node, values) do
    outputs = %{node => ChannelMerge.public_update(values)}
    finished = MapSet.new(for {task_id, "__route__", _value, _path} <- writes, do: task_id)

    to_finish =
      compiled
      |> node_tasks(config, restored, node)
      |> Enum.reject(fn {task_id, _path} -> MapSet.member?(finished, task_id) end)

    {node_routes, other_writes} = Enum.split_with(writes, &(route_node(&1) == node))

    cond do
      to_finish != [] ->
        task_ids = MapSet.new(to_finish, &elem(&1, 0))

        Enum.reject(writes, fn {task_id, _channel, _value, _path} -> MapSet.member?(task_ids, task_id) end) ++
          Enum.map(to_finish, fn {task_id, path} ->
            route_write(task_id, path, %Route{node: node, outputs: outputs}, compiled.graph)
          end)

      node_routes != [] ->
        other_writes ++
          Enum.map(node_routes, fn {task_id, _channel, _value, path} = write ->
            route_write(task_id, path, %{decode_route(write) | outputs: outputs}, compiled.graph)
          end)

      true ->
        step = Replay.initial_step(restored, true)

        task_id = Execution.task_id(compiled.name, config, step, node, {node, "__update__"}, restored.channel_versions)

        writes ++ [route_write(task_id, "", %Route{node: node, outputs: outputs}, compiled.graph)]
    end
  end

  # The stopped step's tasks of `node`: their ids and paths.
  defp node_tasks(compiled, config, restored, node) do
    step = Replay.initial_step(restored, true)

    for request <- restored.next, TaskRequest.name(request) == node, uniq: true do
      raw_path = TaskRequest.raw_path(request)

      {Execution.task_id(compiled.name, config, step, node, raw_path, restored.channel_versions),
       Execution.task_path(raw_path)}
    end
  end

  defp route_node({_task_id, "__route__", _value, _path} = write), do: decode_route(write).node
  defp route_node(_write), do: nil

  defp route_write(task_id, path, %Route{} = route, graph),
    do: {task_id, Route.channel(), Route.encode(route, graph), path}

  defp decode_route(write), do: [write] |> Route.from_writes() |> hd()
end
