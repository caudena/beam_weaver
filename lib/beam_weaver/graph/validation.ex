defmodule BeamWeaver.Graph.Validation do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.NodeSpec
  alias BeamWeaver.Graph.StateGraph
  alias BeamWeaver.Graph.Validation.Report
  alias BeamWeaver.Graph.WaitingEdgeSpec

  @spec validate(StateGraph.t(), keyword()) :: :ok | {:error, BeamWeaver.Core.Error.t()}
  def validate(%StateGraph{} = graph, opts) do
    case report(graph, opts) do
      %Report{diagnostics: []} ->
        :ok

      %Report{diagnostics: [diagnostic | _rest]} ->
        {:error, Error.new(diagnostic.type, diagnostic.message, diagnostic.details)}
    end
  end

  @spec report(StateGraph.t(), keyword()) :: BeamWeaver.Graph.Validation.Report.t()
  def report(%StateGraph{} = graph, opts) do
    validate_static? = Keyword.get(opts, :validate_static, false)

    # Each check: what it found (`nil`, `false` or `[]` for nothing), its
    # message, and its details, or a function of what it found.
    checks = [
      {graph.diagnostics != [], "graph contains duplicate declarations",
       %{duplicates: Enum.reverse(graph.diagnostics)}},
      {map_size(graph.nodes) == 0, "graph must define at least one node", %{}},
      {graph.entry_points == [], "graph must define an entry point", %{}},
      {missing_references(graph), "graph references missing nodes", &%{missing: Enum.sort(&1)}},
      {duplicate_finish_without_node?(graph), "finish points must reference defined nodes", %{}},
      {invalid_nodes(graph), "graph contains invalid nodes", &%{invalid: &1}},
      {invalid_routers(graph), "graph contains invalid conditional routers", &%{invalid: &1}},
      {invalid_reducers(graph), "graph contains invalid reducers", &%{invalid: &1}},
      {invalid_channels(graph), "graph contains invalid channels", &%{invalid: &1}},
      {invalid_managed(graph), "graph contains invalid managed values", &%{invalid: &1}},
      {invalid_reserved_names(graph), "graph uses reserved node or channel names", &%{invalid: &1}},
      {invalid_waiting_edges(graph), "graph contains invalid waiting edges", &%{invalid: &1}},
      {validate_static? and unreachable_nodes(graph), "graph contains unreachable nodes", &%{nodes: &1}},
      {validate_static? and MapSet.size(graph.finish_points) > 0 and dead_end_nodes(graph),
       "graph contains dead-end nodes", &%{nodes: &1}}
    ]

    Report.new(
      for {found, message, details} <- checks, found not in [nil, false, []] do
        %{
          type: :invalid_graph,
          message: message,
          details: if(is_function(details, 1), do: details.(found), else: details)
        }
      end
    )
  end

  defp missing_references(graph) do
    known = MapSet.new(Map.keys(graph.nodes))

    referenced =
      graph.entry_points ++
        Map.keys(graph.edges) ++
        Enum.flat_map(graph.edges, fn {_node, targets} -> targets end) ++
        Map.keys(graph.conditional_edges) ++
        Enum.flat_map(graph.conditional_edges, fn {_node, spec} -> Map.values(spec.path_map) end) ++
        Map.keys(graph.guarded_edges) ++
        Enum.flat_map(graph.guarded_edges, fn {_node, specs} ->
          Enum.flat_map(specs, fn spec -> [spec.source, spec.target] end)
        end) ++
        Enum.flat_map(graph.waiting_edges, fn spec -> spec.upstream ++ [spec.target] end) ++
        Enum.flat_map(graph.nodes, fn {_node, spec} -> spec.deps end) ++
        Enum.flat_map(graph.channel_subscriptions, fn {_channel, nodes} -> nodes end) ++
        MapSet.to_list(graph.finish_points)

    referenced
    |> Enum.reject(&(&1 in ["__start__", "__end__"] or MapSet.member?(known, &1)))
    |> Enum.uniq()
  end

  defp duplicate_finish_without_node?(graph) do
    known = MapSet.new(Map.keys(graph.nodes))
    Enum.any?(graph.finish_points, &(not MapSet.member?(known, &1)))
  end

  # A node whose options were invalid is kept as an `:invalid` spec holding the
  # error, so the graph reports it here instead of running without them.
  defp invalid_nodes(graph) do
    for {name, spec} <- graph.nodes,
        spec.kind == :invalid or not valid_node_callable?(spec.fun),
        do: invalid_node(name, spec)
  end

  defp invalid_node(name, %NodeSpec{kind: :invalid, metadata: %{error: %Error{message: message}}} = spec),
    do: %{node: name, callable: inspect_callable(spec.fun), error: message}

  defp invalid_node(name, spec), do: %{node: name, callable: inspect_callable(spec.fun)}

  defp valid_node_callable?(fun) when is_function(fun, 1), do: true
  defp valid_node_callable?(fun) when is_function(fun, 2), do: true

  defp valid_node_callable?(module) when is_atom(module) do
    function_exported?(module, :invoke, 2)
  end

  defp valid_node_callable?(%Compiled{}), do: true

  defp valid_node_callable?(%{__struct__: module}) do
    Code.ensure_loaded?(module) and
      (function_exported?(module, :invoke, 2) or function_exported?(module, :invoke, 3))
  end

  defp valid_node_callable?(_fun), do: false

  defp invalid_routers(graph) do
    for {source, spec} <- graph.conditional_edges,
        not (is_function(spec.router, 1) or is_function(spec.router, 2)),
        do: %{node: source, router: inspect_callable(spec.router)}
  end

  defp invalid_reducers(graph) do
    for {key, reducer} <- graph.reducers,
        not is_function(reducer, 2),
        do: %{key: key, reducer: inspect_callable(reducer)}
  end

  defp invalid_channels(graph) do
    for {key, channel} <- graph.channels, not valid_channel?(channel), do: %{key: key, channel: inspect(channel)}
  end

  defp invalid_waiting_edges(graph) do
    known = MapSet.new(Map.keys(graph.nodes))

    for %WaitingEdgeSpec{upstream: upstream, target: target} = spec <- graph.waiting_edges,
        not (upstream != [] and Enum.all?(upstream, &MapSet.member?(known, &1)) and MapSet.member?(known, target)),
        do: %{upstream: upstream, target: target, channel: spec.channel}
  end

  defp invalid_reserved_names(graph) do
    reserved_prefixes = ["__branch__:", "__tasks__", "__interrupt__", "__error__", "__barrier__:"]

    node_errors =
      for node <- Map.keys(graph.nodes),
          Enum.any?(reserved_prefixes, &String.starts_with?(node, &1)),
          do: %{kind: :node, name: node}

    channel_errors =
      for key <- Map.keys(graph.channels),
          channel = to_string(key),
          channel in ["__tasks__", "__interrupt__", "__error__"] or String.starts_with?(channel, "__branch__:"),
          do: %{kind: :channel, name: channel}

    node_errors ++ channel_errors
  end

  defp unreachable_nodes(graph) do
    reachable = graph.entry_points |> traverse(adjacency(graph), []) |> MapSet.new()

    graph.nodes
    |> Map.keys()
    |> Enum.reject(&(MapSet.member?(graph.finish_points, &1) or MapSet.member?(reachable, &1)))
    |> Enum.sort()
  end

  defp dead_end_nodes(graph) do
    reverse = add_edges(%{}, for({source, targets} <- adjacency(graph), target <- targets, do: {target, source}))

    can_finish =
      graph.finish_points
      |> MapSet.to_list()
      |> Kernel.++(nodes_routing_to_end(graph))
      |> traverse(reverse, [])
      |> MapSet.new()

    graph.nodes
    |> Map.keys()
    |> Enum.reject(
      &(MapSet.member?(can_finish, &1) or Map.has_key?(graph.conditional_edges, &1) or
          Map.has_key?(graph.guarded_edges, &1))
    )
    |> Enum.sort()
  end

  defp traverse([], _adjacency, seen), do: Enum.reverse(seen)

  defp traverse([node | rest], adjacency, seen) do
    if node in seen do
      traverse(rest, adjacency, seen)
    else
      traverse(Map.get(adjacency, node, []) ++ rest, adjacency, [node | seen])
    end
  end

  defp adjacency(graph) do
    conditional =
      Map.new(graph.conditional_edges, fn {source, spec} ->
        {source, Enum.reject(Map.values(spec.path_map), &(is_nil(&1) or &1 == "__end__"))}
      end)

    guarded =
      Map.new(graph.guarded_edges, fn {source, specs} ->
        {source, for(spec <- specs, spec.target != "__end__", do: spec.target)}
      end)

    # A node that routes with `Command` or `Send` lists its targets in
    # `destinations:`.
    destinations =
      for {node, spec} <- graph.nodes,
          targets = Enum.reject(destinations(spec), &(&1 == "__end__")),
          targets != [],
          into: %{},
          do: {node, targets}

    graph.edges
    |> merge_adjacency(conditional)
    |> merge_adjacency(
      add_edges(%{}, for(spec <- graph.waiting_edges, upstream <- spec.upstream, do: {upstream, spec.target}))
    )
    |> merge_adjacency(guarded)
    |> merge_adjacency(add_edges(%{}, for({node, spec} <- graph.nodes, dep <- spec.deps, do: {dep, node})))
    |> merge_adjacency(destinations)
  end

  defp nodes_routing_to_end(graph) do
    for {node, spec} <- graph.nodes, "__end__" in destinations(spec), do: node
  end

  defp destinations(%{destinations: destinations}) when is_map(destinations),
    do: destinations |> Map.keys() |> Enum.map(&to_string/1)

  defp destinations(%{destinations: destinations}) when is_list(destinations),
    do: Enum.map(destinations, &to_string/1)

  defp destinations(_spec), do: []

  defp add_edges(adjacency, edges),
    do: Enum.reduce(edges, adjacency, fn {from, to}, acc -> Map.update(acc, from, [to], &Enum.uniq(&1 ++ [to])) end)

  defp merge_adjacency(left, right) do
    Enum.reduce(right, left, fn {source, targets}, acc ->
      Map.update(acc, source, targets, &Enum.uniq(&1 ++ targets))
    end)
  end

  defp invalid_managed(graph) do
    for {key, managed} <- graph.managed, not valid_managed?(managed), do: %{key: key, managed: inspect(managed)}
  end

  defp valid_managed?(%{__struct__: module}) do
    Code.ensure_loaded?(module) and function_exported?(module, :get, 2)
  end

  defp valid_managed?(_managed), do: false

  defp valid_channel?(%{__struct__: module}), do: BeamWeaver.Graph.Channel.implemented_by?(module)

  defp valid_channel?(_channel), do: false

  defp inspect_callable(callable) when is_function(callable) do
    {:arity, arity} = :erlang.fun_info(callable, :arity)
    "function/#{arity}"
  end

  defp inspect_callable(callable), do: inspect(callable)
end
