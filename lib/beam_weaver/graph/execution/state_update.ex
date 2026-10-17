defmodule BeamWeaver.Graph.Execution.StateUpdate do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Execution.Route
  alias BeamWeaver.Graph.Execution.Runner
  alias BeamWeaver.Graph.Execution.Scheduler
  alias BeamWeaver.Graph.Execution.Snapshot
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.StateGraph

  @moved_channels ["__interrupt__", "__error__", "__route__"]

  @spec get_state(map(), map()) :: {:ok, map()} | :error | {:error, Error.t()}
  def get_state(%{checkpointer: nil}, _config), do: :error

  def get_state(%{checkpointer: checkpointer} = compiled, config) do
    case SubgraphRouter.namespace_delegate(compiled, config) do
      %{__struct__: _module} = delegate ->
        get_state(delegate, config)

      nil ->
        config = SubgraphRouter.checkpoint_config(compiled, config)

        case Checkpoint.get_tuple(checkpointer, config) do
          nil ->
            :error

          tuple ->
            Snapshot.from_tuple(compiled, tuple, apply_pending?: Snapshot.latest_state?(config))
        end
    end
  end

  @spec get_state_history(map(), map(), keyword()) :: [map()] | {:error, Error.t()}
  def get_state_history(%{checkpointer: nil}, _config, _opts), do: []

  def get_state_history(%{checkpointer: checkpointer} = compiled, config, opts) do
    case SubgraphRouter.namespace_delegate(compiled, config) do
      %{__struct__: _module} = delegate ->
        get_state_history(delegate, config, opts)

      nil ->
        config = SubgraphRouter.checkpoint_config(compiled, config)

        case checkpointer
             |> Checkpoint.list(config, opts)
             |> BeamWeaver.Result.traverse(&Snapshot.from_tuple(compiled, &1, apply_pending?: false)) do
          {:ok, snapshots} -> snapshots
          {:error, %Error{}} = error -> error
        end
    end
  end

  @spec update_state(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def update_state(%{checkpointer: nil}, _config, _values, _opts) do
    {:error, Error.new(:missing_checkpointer, "update_state requires a checkpointer")}
  end

  def update_state(%{} = compiled, config, values, opts) when is_map(values) do
    case SubgraphRouter.namespace_delegate(compiled, config) do
      %{__struct__: _module} = delegate ->
        update_state(delegate, config, values, opts)

      nil ->
        config = SubgraphRouter.checkpoint_config(compiled, config)
        do_update_state(compiled, config, values, opts)
    end
  end

  @spec bulk_update_state(map(), map(), [[map()]], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def bulk_update_state(%{checkpointer: nil}, _config, _supersteps, _opts) do
    {:error, Error.new(:missing_checkpointer, "bulk_update_state requires a checkpointer")}
  end

  def bulk_update_state(%{} = compiled, config, supersteps, opts)
      when is_list(supersteps) do
    case SubgraphRouter.namespace_delegate(compiled, config) do
      %{__struct__: _module} = delegate ->
        bulk_update_state(delegate, config, supersteps, opts)

      nil ->
        config = SubgraphRouter.checkpoint_config(compiled, config)
        do_bulk_update_state(compiled, config, supersteps, opts)
    end
  end

  # An update starts from the thread's whole state, not from what
  # `get_state/2` shows: the progress of joins, the run counts of guarded
  # edges and private keys saved with the thread carry over.
  defp do_update_state(%{} = compiled, config, values, opts) do
    with :ok <- validate_update(compiled.graph, values) do
      case Checkpoint.get_tuple(compiled.checkpointer, config) do
        nil ->
          base = %{values: %{}, channel_versions: %{}, versions_seen: %{}, next: [], tasks: []}
          update_checkpoint(compiled, config, values, opts, base)

        tuple ->
          with {:ok, restored} <- Replay.restore_tuple(compiled, tuple) do
            if Replay.replay_pending?(restored) do
              update_halted(compiled, tuple, restored, values, opts)
            else
              base = Map.put(restored, :tasks, checkpoint_tasks(tuple))
              update_checkpoint(compiled, tuple.config, values, opts, base)
            end
          end
      end
    end
  end

  defp update_checkpoint(compiled, config, values, opts, base) do
    with {:ok, as_node} <- update_as_node(compiled.graph, base.tasks, opts),
         {:ok, updated} <- ChannelMerge.merge_update_result(base.values, values, compiled.graph),
         {:ok, scheduled, ready, updated_channels, step_update} <-
           schedule_routed_after_update(compiled, updated, values, as_node, base),
         channel_versions =
           Execution.next_channel_versions(
             compiled.checkpointer,
             base.channel_versions,
             updated_channels,
             compiled.graph
           ),
         {:ok, updated_config} <-
           CheckpointIO.write_checkpoint(compiled, config, scheduled, %{
             source: "update",
             step: Keyword.get(opts, :step, 0),
             as_node: as_node,
             next: Replay.ready_names(ready),
             next_tasks: Replay.checkpoint_next_records(ready, compiled.graph),
             tasks: [],
             interrupts: [],
             channel_versions: channel_versions,
             versions_seen: base.versions_seen,
             updated_channels: updated_channels,
             step_update: step_update
           }) do
      maybe_resume_after_update(compiled, updated_config, opts)
    end
  end

  # A thread whose last step stopped partway, paused or failed, stays that
  # way: the update goes into that step. The new checkpoint holds the state
  # with the writes of the tasks that finished in the step, plus the update,
  # and the tasks still to run. It keeps the step's number and channel
  # versions, so those tasks keep their ids: the next resume answers their
  # pauses, and a paused subgraph continues from its own checkpoints, which
  # its task's id names. Their pauses and errors move along, as do the routes
  # of the finished tasks, so the step still routes from those when it
  # completes. The checkpoint names the one the step started from, whose
  # state a resumed subgraph's update is measured against.
  #
  # An update made `as_node:` is that node's result in the step: the node's
  # tasks still to run finish with it, or, when the node already finished,
  # it routes with the update as its output; any other node is routed from
  # too. The node arrives at its joins. When no task is left to run, the step
  # completes now.
  defp update_halted(compiled, tuple, restored, values, opts) do
    graph = compiled.graph
    node = node_name(Keyword.get(opts, :as_node))

    ready =
      compiled
      |> Replay.initial_ready(tuple.config, restored, true)
      |> Enum.reject(&(TaskRequest.name(&1) == node))

    writes =
      restored
      |> CheckpointIO.pending_writes_on(@moved_channels)
      |> put_node_result(compiled, tuple, restored, node, values)

    with {:ok, state} <- ChannelMerge.apply_pending_writes(restored.values, restored.pending_writes, graph),
         {:ok, updated} <- ChannelMerge.merge_update_result(state, values, graph),
         {:ok, _arrivals, updated} <- ChannelMerge.merge_step_updates(updated, arrivals(graph, node), graph) do
      if ready == [] do
        complete_halted_step(compiled, tuple, restored, updated, values, writes, opts)
      else
        keep_halted_step(compiled, tuple, restored, updated, values, ready, writes, opts)
      end
    end
  end

  defp keep_halted_step(compiled, tuple, restored, updated, values, ready, writes, opts) do
    metadata = %{
      source: "update",
      step: restored.step,
      as_node: Keyword.get(opts, :as_node),
      next: Replay.ready_names(ready),
      next_tasks: Replay.checkpoint_next_records(ready, compiled.graph),
      tasks: [],
      interrupts: [],
      channel_versions: restored.channel_versions,
      versions_seen: restored.versions_seen,
      updated_channels:
        Execution.normalize_channels(
          Execution.updated_channels(values) ++ Execution.pending_channels(restored.pending_writes)
        ),
      step_update: values,
      step_start: restored.step_start || checkpoint_id(tuple.config)
    }

    with {:ok, updated_config} <- CheckpointIO.write_checkpoint(compiled, tuple.config, updated, metadata),
         :ok <- CheckpointIO.put_task_writes(compiled.checkpointer, updated_config, writes) do
      maybe_resume_after_update(compiled, updated_config, opts)
    end
  end

  # Every task of the stopped step has its result: the step routes from all
  # of them, and the update's checkpoint is the one the step ends with.
  defp complete_halted_step(compiled, tuple, restored, updated, values, writes, opts) do
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
        (Execution.updated_channels(step_update) ++
           schedule.channels ++ Execution.pending_channels(restored.pending_writes))
        |> Execution.normalize_channels()
        |> Enum.reject(&Scheduler.node_outputs_channel?/1)

      next = Scheduler.add_channel_tasks(compiled.plan, schedule.ready, updated_channels)

      metadata = %{
        source: "update",
        step: Replay.initial_step(restored, true),
        as_node: Keyword.get(opts, :as_node),
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

      with {:ok, updated_config} <- CheckpointIO.write_checkpoint(compiled, tuple.config, scheduled, metadata) do
        maybe_resume_after_update(compiled, updated_config, opts)
      end
    end
  end

  # Puts the update in the stopped step as `node`'s result, among the step's
  # writes that move to the new checkpoint (`{task_id, channel, value, path}`).
  defp put_node_result(writes, _compiled, _tuple, _restored, nil, _values), do: writes

  defp put_node_result(writes, compiled, tuple, restored, node, values) do
    outputs = %{node => values}
    finished = MapSet.new(for {task_id, "__route__", _value, _path} <- writes, do: task_id)

    to_finish =
      compiled
      |> node_tasks(tuple, restored, node)
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

        task_id =
          Execution.task_id(compiled.name, tuple.config, step, node, {node, "__update__"}, restored.channel_versions)

        writes ++ [route_write(task_id, "", %Route{node: node, outputs: outputs}, compiled.graph)]
    end
  end

  # The stopped step's tasks of `node`: their ids and paths.
  defp node_tasks(compiled, tuple, restored, node) do
    step = Replay.initial_step(restored, true)

    for request <- restored.next, TaskRequest.name(request) == node, uniq: true do
      raw_path = TaskRequest.raw_path(request)

      {Execution.task_id(compiled.name, tuple.config, step, node, raw_path, restored.channel_versions),
       Execution.task_path(raw_path)}
    end
  end

  defp route_node({_task_id, "__route__", _value, _path} = write), do: decode_route(write).node
  defp route_node(_write), do: nil

  defp route_write(task_id, path, %Route{} = route, graph),
    do: {task_id, Route.channel(), Route.encode(route, graph), path}

  defp decode_route(write), do: [write] |> Route.from_writes() |> hd()

  defp arrivals(_graph, nil), do: []
  defp arrivals(graph, node), do: StateGraph.join_writes(graph, node)

  defp node_name(nil), do: nil
  defp node_name(node), do: to_string(node)

  defp checkpoint_id(config), do: config |> BeamWeaver.Checkpoint.configurable() |> Map.get("checkpoint_id")

  # The update counts as the result of `as_node`: the nodes after it run next,
  # and it arrives at the joins it is upstream of. The tasks the checkpoint
  # already had next stay, except `as_node`'s own, as the update is its
  # result, and those that its edges led to, which its routing from the
  # update replaces.
  defp schedule_routed_after_update(compiled, updated, values, as_node, base) do
    {routes, arrivals} =
      case as_node do
        nil -> {[], []}
        node -> {[%Route{node: to_string(node)}], StateGraph.join_writes(compiled.graph, node)}
      end

    with {:ok, routing_state} <- routing_state_for_update(compiled, updated, as_node, values),
         {:ok, schedule} <- Scheduler.prepare_next_tasks(compiled.plan, routes, routing_state),
         {:ok, schedule_step_update, scheduled} <-
           ChannelMerge.merge_step_updates(updated, schedule.updates ++ arrivals, compiled.graph) do
      {joins, scheduled} = ChannelMerge.fire_joins(%{}, scheduled, compiled.graph)

      step_update =
        values
        |> Map.merge(Scheduler.hide_node_outputs(schedule_step_update))
        |> Map.merge(joins)

      updated_channels =
        (Execution.updated_channels(step_update) ++ schedule.channels)
        |> Execution.normalize_channels()
        |> Enum.reject(&Scheduler.node_outputs_channel?/1)

      ready =
        Scheduler.add_channel_tasks(
          compiled.plan,
          Scheduler.add_tasks(schedule.ready, still_next(compiled.graph, base, as_node)),
          Map.keys(joins)
        )

      {:ok, scheduled, ready, updated_channels, step_update}
    end
  end

  defp routing_state_for_update(_compiled, updated, nil, _values), do: {:ok, updated}

  defp routing_state_for_update(compiled, updated, as_node, values) do
    ChannelMerge.merge_update_result(
      updated,
      %{__node_outputs__: %{to_string(as_node) => values}},
      compiled.graph
    )
  end

  defp still_next(_graph, base, nil), do: base.next

  # The `Send`s that a router returned are its routing too, unless another
  # node that ran last has a router as well.
  defp still_next(graph, base, as_node) do
    node = to_string(as_node)

    others =
      base.tasks
      |> last_finished_task_nodes()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == node))

    led_to_by_others = others |> Enum.flat_map(&edge_targets(graph, &1)) |> MapSet.new()
    replaced = graph |> edge_targets(node) |> MapSet.new() |> MapSet.difference(led_to_by_others)
    sends_replaced? = router?(graph, node) and not Enum.any?(others, &router?(graph, &1))

    Enum.reject(base.next, fn request ->
      cond do
        TaskRequest.name(request) == node -> true
        TaskRequest.kind(request) == :pull -> MapSet.member?(replaced, TaskRequest.name(request))
        TaskRequest.kind(request) == :send -> sends_replaced?
        true -> false
      end
    end)
  end

  defp router?(graph, node), do: Map.has_key?(graph.conditional_edges, node)

  # The nodes that `node`'s edges can lead to. The targets of a `Command`'s
  # `goto`, and the `Send`s a node returns itself, aren't among them: an
  # update can't take them back.
  defp edge_targets(graph, node) do
    conditional =
      case Map.fetch(graph.conditional_edges, node) do
        {:ok, %{path_map: path_map}} when is_map(path_map) -> Map.values(path_map)
        _none -> []
      end

    guarded = graph.guarded_edges |> Map.get(node, []) |> Enum.map(& &1.target)

    graph.edges
    |> Map.get(node, [])
    |> Kernel.++(conditional)
    |> Kernel.++(guarded)
    |> Enum.map(&to_string/1)
  end

  defp update_as_node(graph, tasks, opts) do
    if Keyword.has_key?(opts, :as_node) do
      {:ok, Keyword.get(opts, :as_node)}
    else
      candidates =
        tasks
        |> last_finished_task_nodes()
        |> Enum.filter(&routes_after_update?(graph, &1))
        |> Enum.uniq()

      case candidates do
        [node] ->
          {:ok, node}

        [] ->
          {:ok, nil}

        nodes ->
          {:error, Error.new(:ambiguous_state_update, "could not infer as_node", %{nodes: nodes})}
      end
    end
  end

  defp checkpoint_tasks(%{checkpoint: checkpoint}),
    do: Map.get(checkpoint, "tasks", Map.get(checkpoint, :tasks, []))

  defp last_finished_task_nodes(tasks) do
    tasks
    |> Enum.filter(&(Map.get(&1, :kind) == :finish or Map.get(&1, "kind") == "finish"))
    |> Enum.map(&(Map.get(&1, :node) || Map.get(&1, "node")))
    |> Enum.reject(&is_nil/1)
  end

  defp routes_after_update?(graph, node) do
    Map.has_key?(graph.edges, node) or Map.has_key?(graph.conditional_edges, node) or
      Map.has_key?(graph.guarded_edges, node)
  end

  defp validate_update(graph, values) do
    managed_keys = MapSet.new(Map.keys(graph.managed || %{}), &to_string/1)

    case Enum.find(Map.keys(values), &(to_string(&1) in managed_keys)) do
      nil ->
        :ok

      key ->
        {:error, Error.new(:invalid_update, "managed graph values are read-only", %{key: key})}
    end
  end

  defp maybe_resume_after_update(compiled, updated_config, opts) do
    if Keyword.has_key?(opts, :resume) do
      case Runner.execute(compiled, %{}, Keyword.put(opts, :config, updated_config)) do
        {:parent_command, command} -> CommandRouter.parent_command_error(command)
        result -> result
      end
    else
      {:ok, updated_config}
    end
  end

  defp do_bulk_update_state(%{} = compiled, config, supersteps, opts) do
    cond do
      supersteps == [] ->
        {:error, Error.new(:invalid_update, "bulk update requires at least one superstep")}

      Enum.any?(supersteps, &(&1 == [])) ->
        {:error, Error.new(:invalid_update, "bulk update supersteps cannot be empty")}

      true ->
        reduce_bulk_update_state(compiled, config, supersteps, opts)
    end
  end

  defp reduce_bulk_update_state(%{} = compiled, config, supersteps, opts) do
    initial_state =
      case Checkpoint.get_tuple(compiled.checkpointer, config) do
        nil ->
          {:ok, {config, %{}, %{}, %{}}}

        tuple ->
          with {:ok, restored} <- Replay.restore_tuple(compiled, tuple),
               {:ok, values} <- latest_values(compiled, config, restored) do
            {:ok, {tuple.config, values, restored.channel_versions, restored.versions_seen}}
          end
      end

    with {:ok, {config, values, versions, versions_seen}} <- initial_state do
      supersteps
      |> Enum.with_index(Keyword.get(opts, :step, 0))
      |> Enum.reduce_while({:ok, config, values, versions}, fn
        {updates, step}, {:ok, config, values, versions} when is_list(updates) ->
          case bulk_update_superstep(compiled, config, values, versions, versions_seen, updates, step, opts) do
            {:ok, _config, _values, _versions} = next -> {:cont, next}
            {:error, %Error{}} = error -> {:halt, error}
          end

        _superstep, _acc ->
          {:halt, {:error, Error.new(:invalid_update, "bulk update supersteps must contain update maps")}}
      end)
      |> case do
        {:ok, config, _values, _versions} -> {:ok, config}
        {:error, %Error{}} = error -> error
      end
    end
  end

  # The state that `get_state/2` shows for the config, with the graph's own
  # bookkeeping: the latest checkpoint includes the writes of a step that
  # stopped partway.
  defp latest_values(compiled, config, restored) do
    if Snapshot.latest_state?(config),
      do: ChannelMerge.apply_pending_writes(restored.values, restored.pending_writes, compiled.graph),
      else: {:ok, restored.values}
  end

  defp bulk_update_superstep(compiled, config, values, current_versions, versions_seen, updates, step, opts) do
    updated_channels =
      updates
      |> Enum.flat_map(&Execution.updated_channels/1)
      |> Execution.normalize_channels()

    channel_versions =
      Execution.next_channel_versions(
        compiled.checkpointer,
        current_versions,
        updated_channels,
        compiled.graph
      )

    with {:ok, step_update, next_values} <-
           ChannelMerge.merge_step_updates(values, updates, compiled.graph),
         {:ok, next_config} <-
           CheckpointIO.write_checkpoint(compiled, config, next_values, %{
             source: "update",
             step: step,
             as_node: Keyword.get(opts, :as_node),
             next: [],
             tasks: [],
             interrupts: [],
             channel_versions: channel_versions,
             versions_seen: versions_seen,
             updated_channels: updated_channels,
             step_update: step_update
           }) do
      {:ok, next_config, next_values, channel_versions}
    end
  end
end
