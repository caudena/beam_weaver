defmodule BeamWeaver.Graph.Execution.Scheduler do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Send
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.Plan
  alias BeamWeaver.Graph.Execution.Route
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.GuardedEdgeSpec
  alias BeamWeaver.Graph.Match
  alias BeamWeaver.Result

  @tasks "__tasks__"

  @type ready :: TaskRequest.t() | String.t() | {String.t(), map()}
  @type schedule :: %{ready: [ready()], channels: [String.t()], updates: [map()]}

  defp tasks_from_channels(%Plan{triggers_by_channel: triggers}, updated_channels) do
    pulls =
      for channel <- Execution.normalize_channels(updated_channels),
          node <- Map.get(triggers, channel, []),
          do: TaskRequest.pull(node, [channel])

    add_tasks([], pulls)
  end

  @spec tasks_channel() :: String.t()
  def tasks_channel, do: @tasks

  # The tasks that the step's finished tasks lead to. Each route follows its
  # node's edges, or the nodes its `Command` names in `goto` instead, and adds
  # the `Send`s it returned. Routers, `when:` functions and `deps:` conditions
  # read the state as nodes do, without the graph's bookkeeping; one that
  # raises fails the step with `:edge_exception`.
  @spec prepare_next_tasks(map(), [Route.t()], map()) :: {:ok, schedule()} | {:error, Error.t()}
  def prepare_next_tasks(%Plan{graph: graph} = plan, routes, state) do
    completed = Enum.map(routes, & &1.node)
    visible = ChannelLookup.drop_internal_keys(state)

    with {:ok, node_routes} <- Result.traverse(routes, &node_routes(graph, &1, state, visible)),
         {:ok, dependency_routes} <- dependency_routes(graph, completed, state, visible) do
      route_sends = Enum.flat_map(node_routes, fn {sends, _routes, _updates} -> sends end)
      source_routes = Enum.flat_map(node_routes, fn {_sends, routes, _updates} -> routes end)
      route_updates = Enum.flat_map(node_routes, fn {_sends, _routes, updates} -> updates end)

      dynamic_routes =
        for target <- Enum.map(source_routes, &elem(&1, 1)) ++ dependency_routes,
            target != "__end__",
            do: to_string(target)

      branch_channels =
        for {source, target} <- source_routes,
            target != "__end__",
            do: Plan.branch_channel(source, target)

      send_entries =
        Enum.flat_map(routes, & &1.sends) ++ Enum.map(route_sends, &Route.send_request/1)

      branch_ready =
        plan
        |> tasks_from_channels(branch_channels)
        |> merge_dynamic_routes(dynamic_routes)

      {:ok,
       %{
         ready: add_tasks([], branch_ready ++ send_entries),
         # Sends reach their tasks through the tasks channel.
         channels: Execution.normalize_channels(branch_channels ++ if(send_entries == [], do: [], else: [@tasks])),
         updates: route_updates
       }}
    end
  end

  @spec add_channel_tasks(map(), [ready()], Enumerable.t()) :: [ready()]
  def add_channel_tasks(plan, ready, updated_channels),
    do: add_tasks(ready, tasks_from_channels(plan, updated_channels))

  # Adds `new_tasks` to the tasks of a step. The edges that reach a node in a
  # step run it once, while every `Send` runs as its own task: one like a
  # `Send` the step already has (same node, update and timeout) gets the next
  # `repeat` count, so that its task has its own id.
  @spec add_tasks([ready()], [ready()]) :: [ready()]
  def add_tasks(ready, new_tasks) do
    {added, _seen} =
      Enum.flat_map_reduce(new_tasks, Enum.reduce(ready, %{}, &seen_task/2), &add_task/2)

    ready ++ added
  end

  defp add_task(%TaskRequest{kind: :send} = request, seen) do
    request =
      case Map.fetch(seen, send_key(request)) do
        {:ok, repeat} -> %{request | repeat: repeat + 1}
        :error -> request
      end

    {[request], seen_task(request, seen)}
  end

  defp add_task(task, seen) do
    if Map.has_key?(seen, TaskRequest.key(task)),
      do: {[], seen},
      else: {[task], seen_task(task, seen)}
  end

  # The highest `repeat` count of each `Send`, and the key of every other task.
  defp seen_task(%TaskRequest{kind: :send} = request, seen),
    do: Map.update(seen, send_key(request), request.repeat, &max(&1, request.repeat))

  defp seen_task(task, seen), do: Map.put(seen, TaskRequest.key(task), true)

  defp send_key(%TaskRequest{node: node, update: update, timeout: timeout}),
    do: {:send, node, update, timeout}

  defp node_routes(_graph, %Route{node: node, goto: [_first | _rest] = goto}, _state, _visible),
    do: {:ok, split_source_routes(node, goto, [])}

  defp node_routes(graph, %Route{node: node}, state, visible) do
    edge_call(node, fn ->
      case Map.fetch(graph.conditional_edges, node) do
        {:ok, spec} ->
          split_source_routes(node, route_condition(spec, visible), [])

        :error ->
          static = Map.get(graph.edges, node, [])
          {guarded, updates} = guarded_routes_for_node(graph, node, state, visible)
          split_source_routes(node, static ++ guarded, updates)
      end
    end)
  end

  # Calls the routing of `node`'s edges.
  defp edge_call(node, fun) do
    {:ok, fun.()}
  rescue
    exception ->
      {:error,
       Error.new(:edge_exception, Exception.message(exception), %{
         node: node,
         exception: inspect(exception.__struct__)
       })}
  end

  defp merge_dynamic_routes(branch_ready, dynamic_routes) do
    known = MapSet.new(branch_ready, &TaskRequest.name/1)
    branch_ready ++ for(route <- dynamic_routes, not MapSet.member?(known, route), do: TaskRequest.pull(route))
  end

  defp guarded_routes_for_node(graph, node, state, visible) do
    {defaults, guarded} = graph.guarded_edges |> Map.get(node, []) |> Enum.split_with(& &1.default?)

    matched = Enum.filter(guarded, &guarded_edge_matches?(&1, state, visible))

    selected =
      if matched == [], do: Enum.filter(defaults, &edge_under_limit?(&1, state)), else: matched

    updates = for %{max_runs: max_runs} = spec <- selected, max_runs, do: %{__edge_runs__: %{spec.id => 1}}

    {Enum.map(selected, & &1.target), updates}
  end

  defp guarded_edge_matches?(%GuardedEdgeSpec{} = spec, state, visible) do
    edge_under_limit?(spec, state) and
      Match.match?(spec.match, node_output(state, spec.source), visible)
  end

  defp edge_under_limit?(%GuardedEdgeSpec{max_runs: nil}, _state), do: true

  defp edge_under_limit?(%GuardedEdgeSpec{max_runs: max_runs} = spec, state)
       when is_integer(max_runs) do
    runs = Map.get(state, :__edge_runs__, Map.get(state, "__edge_runs__", %{}))
    Map.get(runs, spec.id, Map.get(runs, to_string(spec.id), 0)) < max_runs
  end

  defp edge_under_limit?(_spec, _state), do: true

  defp dependency_routes(graph, completed, state, visible) do
    graph.nodes
    |> Enum.filter(fn {_node, spec} ->
      spec.condition && spec.deps != [] && Enum.any?(spec.deps, &(&1 in completed)) &&
        deps_ready?(state, spec.deps)
    end)
    |> Result.flat_traverse(fn {node, spec} ->
      edge_call(node, fn ->
        if dependency_condition_matches?(state, visible, spec.deps, spec.condition), do: [node], else: []
      end)
    end)
  end

  defp deps_ready?(state, deps), do: Enum.all?(deps, &node_output_present?(state, &1))

  defp dependency_condition_matches?(state, visible, deps, condition) do
    Enum.all?(deps, fn dep -> Match.match?(condition, node_output(state, dep), visible) end)
  end

  defp node_output_present?(state, node) do
    outputs = Map.get(state, :__node_outputs__, Map.get(state, "__node_outputs__", %{}))
    Map.has_key?(outputs, node) or Map.has_key?(outputs, to_string(node))
  end

  defp node_output(state, node) do
    outputs = Map.get(state, :__node_outputs__, Map.get(state, "__node_outputs__", %{}))
    Map.get(outputs, node, Map.get(outputs, to_string(node)))
  end

  defp split_source_routes(source, route_outputs, updates) do
    {sends, routes} = Enum.split_with(route_outputs, &match?(%Send{}, &1))
    {sends, Enum.map(routes, &{source, to_string(&1)}), updates}
  end

  # Drops the per-step node-output channel from an update shown to callers.
  def hide_node_outputs(update), do: update |> Map.delete(:__node_outputs__) |> Map.delete("__node_outputs__")

  def node_outputs_channel?(channel), do: to_string(channel) == "__node_outputs__"

  defp route_condition(spec, state) do
    result =
      case :erlang.fun_info(spec.router, :arity) do
        {:arity, 1} -> spec.router.(state)
        {:arity, 2} -> spec.router.(state, spec.path_map)
      end

    result
    |> List.wrap()
    |> Enum.map(fn
      %Send{} = send -> send
      route -> Map.get(spec.path_map, route, to_string(route))
    end)
    |> Enum.reject(&(&1 == "__end__"))
  end
end
