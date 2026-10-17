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

    []
    |> maybe_add_diagnostic(
      graph.diagnostics != [],
      "graph contains duplicate declarations",
      %{duplicates: Enum.reverse(graph.diagnostics)}
    )
    |> maybe_add_diagnostic(
      map_size(graph.nodes) == 0,
      "graph must define at least one node",
      %{}
    )
    |> maybe_add_diagnostic(
      graph.entry_points == [],
      "graph must define an entry point",
      %{}
    )
    |> maybe_add_diagnostic(
      missing_references(graph),
      "graph references missing nodes",
      fn missing -> %{missing: Enum.sort(missing)} end
    )
    |> maybe_add_diagnostic(
      duplicate_finish_without_node?(graph),
      "finish points must reference defined nodes",
      %{}
    )
    |> maybe_add_diagnostic(
      invalid_nodes(graph),
      "graph contains invalid nodes",
      &%{invalid: &1}
    )
    |> maybe_add_diagnostic(
      invalid_routers(graph),
      "graph contains invalid conditional routers",
      &%{invalid: &1}
    )
    |> maybe_add_diagnostic(
      invalid_reducers(graph),
      "graph contains invalid reducers",
      &%{invalid: &1}
    )
    |> maybe_add_diagnostic(
      invalid_channels(graph),
      "graph contains invalid channels",
      &%{invalid: &1}
    )
    |> maybe_add_diagnostic(
      invalid_managed(graph),
      "graph contains invalid managed values",
      &%{invalid: &1}
    )
    |> maybe_add_diagnostic(
      invalid_reserved_names(graph),
      "graph uses reserved node or channel names",
      &%{invalid: &1}
    )
    |> maybe_add_diagnostic(
      invalid_waiting_edges(graph),
      "graph contains invalid waiting edges",
      &%{invalid: &1}
    )
    |> maybe_add_diagnostic(
      static_unreachable_nodes(graph, validate_static?),
      "graph contains unreachable nodes",
      &%{nodes: &1}
    )
    |> maybe_add_diagnostic(
      static_dead_end_nodes(graph, validate_static?),
      "graph contains dead-end nodes",
      &%{nodes: &1}
    )
    |> Enum.reverse()
    |> Report.new()
  end

  defp maybe_add_diagnostic(diagnostics, value, _message, _details) when value in [nil, false, []],
    do: diagnostics

  defp maybe_add_diagnostic(diagnostics, true, message, details) when is_map(details) do
    add_diagnostic(diagnostics, message, details)
  end

  defp maybe_add_diagnostic(diagnostics, value, message, details_fun)
       when is_function(details_fun, 1) do
    add_diagnostic(diagnostics, message, details_fun.(value))
  end

  defp add_diagnostic(diagnostics, message, details) do
    [%{type: :invalid_graph, message: message, details: details} | diagnostics]
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
        Enum.flat_map(graph.nodes, fn {_node, spec} -> List.wrap(spec.deps) end) ++
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
    graph.nodes
    |> Enum.filter(fn {_name, spec} -> spec.kind == :invalid or not valid_node_callable?(spec.fun) end)
    |> Enum.map(fn {name, spec} -> invalid_node(name, spec) end)
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
    graph.conditional_edges
    |> Enum.reject(fn {_source, spec} -> is_function(spec.router, 1) or is_function(spec.router, 2) end)
    |> Enum.map(fn {source, spec} -> %{node: source, router: inspect_callable(spec.router)} end)
  end

  defp invalid_reducers(graph) do
    graph.reducers
    |> Enum.reject(fn {_key, reducer} -> is_function(reducer, 2) end)
    |> Enum.map(fn {key, reducer} -> %{key: key, reducer: inspect_callable(reducer)} end)
  end

  defp invalid_channels(graph) do
    graph.channels
    |> Enum.reject(fn {_key, channel} -> valid_channel?(channel) end)
    |> Enum.map(fn {key, channel} -> %{key: key, channel: inspect(channel)} end)
  end

  defp invalid_waiting_edges(graph) do
    known = MapSet.new(Map.keys(graph.nodes))

    graph.waiting_edges
    |> Enum.reject(fn %WaitingEdgeSpec{upstream: upstream, target: target} ->
      upstream != [] and
        Enum.all?(upstream, &MapSet.member?(known, &1)) and
        MapSet.member?(known, target)
    end)
    |> Enum.map(fn %WaitingEdgeSpec{} = spec ->
      %{upstream: spec.upstream, target: spec.target, channel: spec.channel}
    end)
  end

  defp invalid_reserved_names(graph) do
    reserved_prefixes = ["__branch__:", "__tasks__", "__interrupt__", "__error__", "__barrier__:"]

    node_errors =
      graph.nodes
      |> Map.keys()
      |> Enum.filter(fn node ->
        Enum.any?(reserved_prefixes, &String.starts_with?(node, &1))
      end)
      |> Enum.map(&%{kind: :node, name: &1})

    channel_errors =
      graph.channels
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.filter(fn channel ->
        channel in ["__tasks__", "__interrupt__", "__error__"] or
          String.starts_with?(channel, "__branch__:")
      end)
      |> Enum.map(&%{kind: :channel, name: &1})

    node_errors ++ channel_errors
  end

  defp unreachable_nodes(graph) do
    reachable = graph.entry_points |> traverse(adjacency(graph), []) |> MapSet.new()

    graph.nodes
    |> Map.keys()
    |> Enum.reject(&(MapSet.member?(graph.finish_points, &1) or MapSet.member?(reachable, &1)))
    |> Enum.sort()
  end

  defp static_unreachable_nodes(_graph, false), do: nil
  defp static_unreachable_nodes(graph, true), do: unreachable_nodes(graph)

  defp static_dead_end_nodes(_graph, false), do: nil
  defp static_dead_end_nodes(graph, true), do: dead_end_nodes(graph)

  defp dead_end_nodes(graph) do
    if MapSet.size(graph.finish_points) == 0 do
      nil
    else
      do_dead_end_nodes(graph)
    end
  end

  defp do_dead_end_nodes(graph) do
    reverse =
      graph
      |> adjacency()
      |> Enum.reduce(%{}, fn {source, targets}, acc ->
        Enum.reduce(targets, acc, fn target, inner ->
          Map.update(inner, target, [source], &Enum.uniq(&1 ++ [source]))
        end)
      end)

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
      graph.conditional_edges
      |> Enum.map(fn {source, spec} ->
        targets =
          spec.path_map
          |> Map.values()
          |> Enum.reject(&(is_nil(&1) or &1 == "__end__"))

        {source, targets}
      end)
      |> Map.new()

    waiting =
      Enum.reduce(graph.waiting_edges, %{}, fn spec, acc ->
        Enum.reduce(spec.upstream, acc, fn upstream, inner ->
          Map.update(inner, upstream, [spec.target], &Enum.uniq(&1 ++ [spec.target]))
        end)
      end)

    graph.edges
    |> merge_adjacency(conditional)
    |> merge_adjacency(waiting)
    |> merge_adjacency(guarded_adjacency(graph))
    |> merge_adjacency(dependency_adjacency(graph))
    |> merge_adjacency(destination_adjacency(graph))
  end

  # A node that routes with `Command` or `Send` lists its targets in
  # `destinations:`.
  defp destination_adjacency(graph) do
    graph.nodes
    |> Enum.map(fn {node, spec} ->
      {node, spec |> destinations() |> Enum.reject(&(&1 == "__end__"))}
    end)
    |> Enum.reject(fn {_node, targets} -> targets == [] end)
    |> Map.new()
  end

  defp nodes_routing_to_end(graph) do
    for {node, spec} <- graph.nodes, "__end__" in destinations(spec), do: node
  end

  defp destinations(%{destinations: destinations}) when is_map(destinations),
    do: destinations |> Map.keys() |> Enum.map(&to_string/1)

  defp destinations(%{destinations: destinations}) when is_list(destinations),
    do: Enum.map(destinations, &to_string/1)

  defp destinations(_spec), do: []

  defp guarded_adjacency(graph) do
    graph.guarded_edges
    |> Enum.map(fn {source, specs} ->
      targets =
        specs
        |> Enum.map(& &1.target)
        |> Enum.reject(&(&1 == "__end__"))

      {source, targets}
    end)
    |> Map.new()
  end

  defp dependency_adjacency(graph) do
    Enum.reduce(graph.nodes, %{}, fn {node, spec}, acc ->
      Enum.reduce(spec.deps, acc, fn dep, inner ->
        Map.update(inner, dep, [node], &Enum.uniq(&1 ++ [node]))
      end)
    end)
  end

  defp merge_adjacency(left, right) do
    Enum.reduce(right, left, fn {source, targets}, acc ->
      Map.update(acc, source, targets, &Enum.uniq(&1 ++ targets))
    end)
  end

  defp invalid_managed(graph) do
    graph.managed
    |> Enum.reject(fn {_key, managed} -> valid_managed?(managed) end)
    |> Enum.map(fn {key, managed} -> %{key: key, managed: inspect(managed)} end)
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
