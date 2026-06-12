defmodule BeamWeaver.Graph.Execution.Scheduler do
  @moduledoc """
  Channel-triggered graph scheduling helpers.

  The public `StateGraph` API remains edge-based. Internally we derive
  synthetic branch channels from edges and conditionals so the runtime can make
  LangGraph-style decisions from channel updates rather than from a mutable
  ready list.
  """

  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.Plan
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.GuardedEdgeSpec
  alias BeamWeaver.Graph.Match

  @start "__start__"
  @tasks "__tasks__"

  @type ready :: TaskRequest.t() | String.t() | {String.t(), map()}

  @spec trigger_to_nodes(map()) :: map()
  def trigger_to_nodes(%Plan{triggers_by_channel: triggers}), do: triggers

  def trigger_to_nodes(graph) do
    graph
    |> Plan.from()
    |> trigger_to_nodes()
  end

  @spec entry_channels(map()) :: [String.t()]
  def entry_channels(%Plan{entry_requests: entries}) do
    entries
    |> Enum.flat_map(& &1.triggers)
    |> Execution.normalize_channels()
  end

  def entry_channels(graph), do: Enum.map(graph.entry_points, &branch_channel(@start, &1))

  @spec ready_from_channels(map(), Enumerable.t()) :: [String.t()]
  def ready_from_channels(graph, updated_channels) do
    triggers = trigger_to_nodes(graph)

    updated_channels
    |> Execution.normalize_channels()
    |> Enum.flat_map(&Map.get(triggers, &1, []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec tasks_from_channels(map(), Enumerable.t()) :: [TaskRequest.t()]
  def tasks_from_channels(graph, updated_channels) do
    triggers = trigger_to_nodes(graph)

    updated_channels
    |> Execution.normalize_channels()
    |> Enum.flat_map(fn channel ->
      triggers
      |> Map.get(channel, [])
      |> Enum.map(&TaskRequest.pull(&1, [channel]))
    end)
    |> uniq_tasks()
  end

  @doc false
  @spec branch_channel(atom() | String.t(), atom() | String.t()) :: String.t()
  defdelegate branch_channel(source, target), to: Plan

  @spec tasks_channel() :: String.t()
  def tasks_channel, do: @tasks

  @spec prepare_next_tasks(map(), [ready()], map(), [term()], [term()], function()) ::
          %{ready: [ready()], channels: [String.t()], updates: [map()]}
  def prepare_next_tasks(plan_or_graph, completed, state, explicit_next, sends, route_condition) do
    graph = graph_for(plan_or_graph)
    completed = Enum.map(completed, &TaskRequest.name/1)

    {route_sends, source_routes, route_updates} =
      completed
      |> Enum.reduce({[], [], []}, fn node, {sends_acc, routes_acc, updates_acc} ->
        {sends, routes, updates} =
          cond do
            explicit = explicit_routes_for(node, completed, explicit_next) ->
              split_source_routes(node, explicit, [])

            Map.has_key?(graph.conditional_edges, node) ->
              split_source_routes(
                node,
                route_condition.(Map.fetch!(graph.conditional_edges, node), state),
                []
              )

            true ->
              static = Map.get(graph.edges, node, [])
              {guarded, updates} = guarded_routes_for_node(graph, node, state)
              split_source_routes(node, static ++ guarded, updates)
          end

        {
          prepend_all(sends, sends_acc),
          prepend_all(routes, routes_acc),
          prepend_all(updates, updates_acc)
        }
      end)
      |> reverse_route_accumulators()

    dependency_routes = dependency_routes(graph, completed, state)

    dynamic_routes =
      source_routes
      |> Enum.map(fn {_source, target} -> target end)
      |> Kernel.++(dependency_routes)
      |> Enum.reject(&(&1 == "__end__"))
      |> Enum.map(&to_string/1)

    branch_channels =
      for {source, target} <- source_routes,
          target != "__end__",
          do: branch_channel(source, target)

    send_entries =
      Enum.map(sends ++ route_sends, fn send ->
        TaskRequest.send(send.node, send.update || %{}, [@tasks], timeout: send.timeout)
      end)

    send_channels = if send_entries == [], do: [], else: [@tasks]

    branch_ready =
      plan_or_graph
      |> tasks_from_channels(branch_channels)
      |> merge_dynamic_routes(dynamic_routes)

    %{
      ready: uniq_tasks(branch_ready ++ send_entries),
      channels: Execution.normalize_channels(branch_channels ++ send_channels),
      updates: route_updates
    }
  end

  @spec add_channel_tasks(map(), [ready()], Enumerable.t()) :: [ready()]
  def add_channel_tasks(plan_or_graph, ready, updated_channels) do
    ready
    |> Kernel.++(tasks_from_channels(plan_or_graph, updated_channels))
    |> uniq_tasks()
  end

  defp graph_for(%Plan{graph: graph}), do: graph
  defp graph_for(graph), do: graph

  defp explicit_routes_for(node, completed, explicit_next) do
    explicit = Enum.map(explicit_next, &to_string/1)

    if explicit != [] and node in completed,
      do: explicit,
      else: nil
  end

  defp merge_dynamic_routes(branch_ready, dynamic_routes) do
    known = MapSet.new(branch_ready, &TaskRequest.name/1)

    extra =
      dynamic_routes
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(&TaskRequest.pull/1)

    branch_ready ++ extra
  end

  defp guarded_routes_for_node(graph, node, state) do
    specs = Map.get(graph.guarded_edges, node, [])

    {defaults, guarded} = Enum.split_with(specs, & &1.default?)

    matched =
      guarded
      |> Enum.filter(&guarded_edge_matches?(&1, state))

    selected =
      if matched == [], do: Enum.filter(defaults, &edge_under_limit?(&1, state)), else: matched

    updates =
      selected
      |> Enum.filter(& &1.max_runs)
      |> Enum.map(fn spec -> %{__edge_runs__: %{spec.id => 1}} end)

    {Enum.map(selected, & &1.target), updates}
  end

  defp guarded_edge_matches?(%GuardedEdgeSpec{} = spec, state) do
    edge_under_limit?(spec, state) and
      Match.match?(spec.match, node_output(state, spec.source), state)
  end

  defp edge_under_limit?(%GuardedEdgeSpec{max_runs: nil}, _state), do: true

  defp edge_under_limit?(%GuardedEdgeSpec{max_runs: max_runs} = spec, state)
       when is_integer(max_runs) do
    edge_run_count(state, spec.id) < max_runs
  end

  defp edge_under_limit?(_spec, _state), do: true

  defp edge_run_count(state, id) do
    runs = Map.get(state, :__edge_runs__, Map.get(state, "__edge_runs__", %{}))
    Map.get(runs, id, Map.get(runs, to_string(id), 0))
  end

  defp dependency_routes(graph, completed, state) do
    graph.nodes
    |> Enum.filter(fn {_node, spec} ->
      spec.condition && spec.deps != [] && Enum.any?(spec.deps, &(&1 in completed))
    end)
    |> Enum.filter(fn {_node, spec} -> deps_ready?(state, spec.deps) end)
    |> Enum.filter(fn {_node, spec} ->
      dependency_condition_matches?(state, spec.deps, spec.condition)
    end)
    |> Enum.map(fn {node, _spec} -> node end)
  end

  defp deps_ready?(state, deps), do: Enum.all?(deps, &node_output_present?(state, &1))

  defp dependency_condition_matches?(state, [dep], condition),
    do: Match.match?(condition, node_output(state, dep), state)

  defp dependency_condition_matches?(state, deps, condition) do
    Enum.all?(deps, fn dep -> Match.match?(condition, node_output(state, dep), state) end)
  end

  defp node_output_present?(state, node) do
    outputs = Map.get(state, :__node_outputs__, Map.get(state, "__node_outputs__", %{}))
    Map.has_key?(outputs, node) or Map.has_key?(outputs, to_string(node))
  end

  defp node_output(state, node) do
    outputs = Map.get(state, :__node_outputs__, Map.get(state, "__node_outputs__", %{}))
    Map.get(outputs, node, Map.get(outputs, to_string(node)))
  end

  defp uniq_tasks(tasks) do
    Enum.uniq_by(tasks, fn task ->
      {TaskRequest.kind(task), TaskRequest.name(task), TaskRequest.update(task)}
    end)
  end

  defp split_source_routes(source, route_outputs, updates) do
    {sends, routes} =
      route_outputs
      |> List.wrap()
      |> Enum.reduce({[], []}, fn
        %BeamWeaver.Graph.Send{} = send, {sends, routes} ->
          {[send | sends], routes}

        route, {sends, routes} ->
          {sends, [{source, to_string(route)} | routes]}
      end)

    {Enum.reverse(sends), Enum.reverse(routes), updates}
  end

  defp prepend_all(values, acc), do: Enum.reduce(values, acc, &[&1 | &2])

  defp reverse_route_accumulators({sends, routes, updates}) do
    {Enum.reverse(sends), Enum.reverse(routes), Enum.reverse(updates)}
  end
end
