defmodule BeamWeaver.Graph.Execution.StateUpdate do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.DeltaReplay
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Execution.Route
  alias BeamWeaver.Graph.Execution.Runner
  alias BeamWeaver.Graph.Execution.Scheduler
  alias BeamWeaver.Graph.Execution.Snapshot
  alias BeamWeaver.Graph.Execution.StoppedStep
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.StateGraph

  @new_base %{values: %{}, channel_versions: %{}, versions_seen: %{}, next: [], tasks: [], known_checkpoint: nil}

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

        # Each checkpoint's delta channel values come from its parent's.
        case checkpointer
             |> Checkpoint.list(config, opts)
             |> then(&DeltaReplay.put_history_values(compiled, &1))
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
        do_update_state(compiled, config, ChannelMerge.prepare_update(values, compiled.graph), opts)
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
  # edges and private keys saved with the thread carry over. A thread whose
  # last step stopped partway gets the update in that step.
  defp do_update_state(%{} = compiled, config, values, opts) do
    with :ok <- validate_update(compiled.graph, values),
         {:ok, loaded} <- load(compiled, config),
         {:ok, updated_config} <- save_update(compiled, config, loaded, values, opts) do
      maybe_resume_after_update(compiled, updated_config, opts)
    end
  end

  defp save_update(compiled, config, :new, values, opts) do
    with {:ok, updated_config, _base} <- write_update(compiled, config, @new_base, {:update, values}, step(opts), opts),
         do: {:ok, updated_config}
  end

  defp save_update(compiled, _config, {:stopped, tuple, restored}, values, opts),
    do: StoppedStep.save(compiled, tuple.config, restored, {:update, values}, Keyword.get(opts, :as_node), nil)

  defp save_update(compiled, _config, {:completed, tuple, restored}, values, opts) do
    base = Map.put(restored, :tasks, checkpoint_tasks(tuple))

    with {:ok, updated_config, _base} <- write_update(compiled, tuple.config, base, {:update, values}, step(opts), opts),
         do: {:ok, updated_config}
  end

  # The checkpoint `config` names, restored: none yet, one whose last step
  # stopped partway, or one whose last step completed.
  defp load(compiled, config) do
    case Checkpoint.get_tuple(compiled.checkpointer, config) do
      nil ->
        {:ok, :new}

      tuple ->
        with {:ok, restored} <- Replay.restore_tuple(compiled, tuple) do
          if Replay.replay_pending?(restored),
            do: {:ok, {:stopped, tuple, restored}},
            else: {:ok, {:completed, tuple, restored}}
        end
    end
  end

  # Saves `update` on top of `base` as the result of the node it counts as,
  # which routes from it, and returns the new checkpoint's config and `base`
  # as of that checkpoint.
  defp write_update(compiled, config, base, update, step, opts) do
    graph = compiled.graph

    with {:ok, as_node} <- update_as_node(graph, base.tasks, opts),
         {:ok, step_update, updated} <- ChannelMerge.merge_state_update(base.values, update, graph),
         {:ok, scheduled, ready, updated_channels, step_update} <-
           schedule_routed_after_update(compiled, updated, step_update, as_node, base),
         channel_versions =
           Execution.next_channel_versions(compiled.checkpointer, base.channel_versions, updated_channels, graph),
         {:ok, updated_config, known} <-
           CheckpointIO.write_checkpoint(
             compiled,
             config,
             scheduled,
             %{
               source: "update",
               step: step,
               as_node: as_node,
               next: Replay.ready_names(ready),
               next_tasks: Replay.checkpoint_next_records(ready, graph),
               tasks: [],
               interrupts: [],
               channel_versions: channel_versions,
               versions_seen: base.versions_seen,
               updated_channels: updated_channels,
               step_update: step_update
             },
             base.known_checkpoint
           ) do
      {:ok, updated_config,
       %{base | values: scheduled, channel_versions: channel_versions, next: ready, tasks: [], known_checkpoint: known}}
    end
  end

  defp step(opts), do: Keyword.get(opts, :step, 0)

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
      %{__node_outputs__: %{to_string(as_node) => ChannelMerge.public_update(values)}},
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

      not Enum.all?(supersteps, &is_list/1) ->
        {:error, Error.new(:invalid_update, "bulk update supersteps must contain update maps")}

      Enum.any?(supersteps, &(&1 == [])) ->
        {:error, Error.new(:invalid_update, "bulk update supersteps cannot be empty")}

      true ->
        reduce_bulk_update_state(compiled, config, supersteps, opts)
    end
  end

  # Each superstep is an update as `update_state/4` makes one: made `as_node:`,
  # it routes from that node, and the tasks the thread still had to run, such
  # as one waiting at a breakpoint, stay, except those its routing replaces.
  # A superstep made while the thread's last step is stopped partway goes into
  # that step, so its pauses, errors and the routes of its finished tasks stay.
  defp reduce_bulk_update_state(%{} = compiled, config, supersteps, opts) do
    with {:ok, loaded} <- load(compiled, config), do: bulk_update_from(compiled, config, loaded, supersteps, opts)
  end

  defp bulk_update_from(compiled, config, :new, supersteps, opts),
    do: bulk_update_supersteps(compiled, config, @new_base, supersteps, opts)

  defp bulk_update_from(compiled, _config, {:stopped, tuple, restored}, [updates | rest], opts) do
    as_node = Keyword.get(opts, :as_node)

    with {:ok, updated_config} <-
           StoppedStep.save(compiled, tuple.config, restored, {:superstep, updates}, as_node, nil) do
      case rest do
        [] -> {:ok, updated_config}
        rest -> reduce_bulk_update_state(compiled, updated_config, rest, Keyword.update(opts, :step, 1, &(&1 + 1)))
      end
    end
  end

  defp bulk_update_from(compiled, config, {:completed, tuple, restored}, supersteps, opts) do
    with {:ok, values} <- latest_values(compiled, config, restored) do
      base = %{
        values: values,
        channel_versions: restored.channel_versions,
        versions_seen: restored.versions_seen,
        next: restored.next,
        tasks: checkpoint_tasks(tuple),
        known_checkpoint: restored.known_checkpoint
      }

      bulk_update_supersteps(compiled, tuple.config, base, supersteps, opts)
    end
  end

  defp bulk_update_supersteps(compiled, config, base, supersteps, opts) do
    supersteps
    |> Enum.with_index(step(opts))
    |> Enum.reduce_while({:ok, config, base}, fn {updates, step}, {:ok, config, base} ->
      case write_update(compiled, config, base, {:superstep, updates}, step, opts) do
        {:ok, _config, _base} = next -> {:cont, next}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, config, _base} -> {:ok, config}
      {:error, %Error{}} = error -> error
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
end
