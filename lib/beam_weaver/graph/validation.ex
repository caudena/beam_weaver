defmodule BeamWeaver.Graph.Validation do
  @moduledoc """
  Graph validation.

  `StateGraph` owns immutable builder data. This module owns validation so the
  builder does not also carry graph analysis and diagnostics logic.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.NodeSpec
  alias BeamWeaver.Graph.StateGraph
  alias BeamWeaver.Graph.Validation.Report
  alias BeamWeaver.Graph.WaitingEdgeSpec

  @spec validate(StateGraph.t(), keyword()) :: :ok | {:error, BeamWeaver.Core.Error.t()}
  def validate(%StateGraph{} = graph, opts \\ []) do
    case report(graph, opts) do
      %Report{diagnostics: []} ->
        :ok

      %Report{diagnostics: [diagnostic | _rest]} ->
        {:error, Error.new(diagnostic.type, diagnostic.message, diagnostic.details)}
    end
  end

  @spec report(StateGraph.t(), keyword()) :: BeamWeaver.Graph.Validation.Report.t()
  def report(%StateGraph{} = graph, opts \\ []) do
    validate_static? = normalize_validate_static(opts)

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
      "graph contains invalid node callables",
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

  defp normalize_validate_static(value) when is_boolean(value), do: value
  defp normalize_validate_static(opts), do: Keyword.get(opts, :validate_static, false)

  defp maybe_add_diagnostic(diagnostics, nil, _message, _details), do: diagnostics
  defp maybe_add_diagnostic(diagnostics, false, _message, _details), do: diagnostics
  defp maybe_add_diagnostic(diagnostics, [], _message, _details), do: diagnostics

  defp maybe_add_diagnostic(diagnostics, true, message, details) when is_map(details) do
    add_diagnostic(diagnostics, message, details)
  end

  defp maybe_add_diagnostic(diagnostics, value, message, details_fun)
       when is_function(details_fun, 1) do
    add_diagnostic(diagnostics, message, details_fun.(value))
  end

  defp maybe_add_diagnostic(diagnostics, value, message, details) when is_map(details) do
    add_diagnostic(diagnostics, message, Map.put(details, :value, value))
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
        Enum.flat_map(graph.conditional_edges, fn {_node, spec} -> List.wrap(spec.then) end) ++
        Map.keys(graph.guarded_edges) ++
        Enum.flat_map(graph.guarded_edges, fn {_node, specs} ->
          Enum.flat_map(specs, fn spec -> [spec.source, spec.target] end)
        end) ++
        Enum.flat_map(graph.waiting_edges, fn spec -> spec.upstream ++ [spec.target] end) ++
        Enum.flat_map(graph.nodes, fn {_node, spec} -> List.wrap(spec.deps) end) ++
        Enum.flat_map(graph.channel_subscriptions, fn {_channel, nodes} -> nodes end) ++
        MapSet.to_list(graph.finish_points)

    missing =
      referenced
      |> Enum.reject(&(&1 in ["__start__", "__end__"]))
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.uniq()

    if missing == [], do: nil, else: missing
  end

  defp duplicate_finish_without_node?(graph) do
    known = MapSet.new(Map.keys(graph.nodes))
    Enum.any?(graph.finish_points, &(not MapSet.member?(known, &1)))
  end

  defp invalid_nodes(graph) do
    invalid =
      graph.nodes
      |> Enum.reject(fn {_name, spec} -> valid_node_callable?(spec.fun) end)
      |> Enum.map(fn {name, spec} -> %{node: name, callable: inspect_callable(spec.fun)} end)

    if invalid == [], do: nil, else: invalid
  end

  defp valid_node_callable?(fun) when is_function(fun, 1), do: true
  defp valid_node_callable?(fun) when is_function(fun, 2), do: true
  defp valid_node_callable?(%NodeSpec{kind: kind}) when kind != :invalid, do: true
  defp valid_node_callable?(%NodeSpec{}), do: false

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
    invalid =
      graph.conditional_edges
      |> Enum.reject(fn {_source, spec} -> valid_router?(spec.router) end)
      |> Enum.map(fn {source, spec} -> %{node: source, router: inspect_callable(spec.router)} end)

    if invalid == [], do: nil, else: invalid
  end

  defp valid_router?(router) when is_function(router, 1), do: true
  defp valid_router?(router) when is_function(router, 2), do: true
  defp valid_router?(_router), do: false

  defp invalid_reducers(graph) do
    invalid =
      graph.reducers
      |> Enum.reject(fn {_key, reducer} -> is_function(reducer, 2) end)
      |> Enum.map(fn {key, reducer} -> %{key: key, reducer: inspect_callable(reducer)} end)

    if invalid == [], do: nil, else: invalid
  end

  defp invalid_channels(graph) do
    invalid =
      graph.channels
      |> Enum.reject(fn {_key, channel} -> valid_channel?(channel) end)
      |> Enum.map(fn {key, channel} -> %{key: key, channel: inspect(channel)} end)

    if invalid == [], do: nil, else: invalid
  end

  defp invalid_waiting_edges(graph) do
    known = MapSet.new(Map.keys(graph.nodes))

    invalid =
      graph.waiting_edges
      |> Enum.reject(fn %WaitingEdgeSpec{upstream: upstream, target: target} ->
        upstream != [] and
          Enum.all?(upstream, &MapSet.member?(known, &1)) and
          MapSet.member?(known, target)
      end)
      |> Enum.map(fn %WaitingEdgeSpec{} = spec ->
        %{upstream: spec.upstream, target: spec.target, channel: spec.channel}
      end)

    if invalid == [], do: nil, else: invalid
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
      |> Enum.reject(&String.starts_with?(&1, "__barrier__:"))
      |> Enum.map(&%{kind: :channel, name: &1})

    invalid = node_errors ++ channel_errors
    if invalid == [], do: nil, else: invalid
  end

  defp unreachable_nodes(graph) do
    reachable =
      graph.entry_points
      |> traverse(graph)
      |> MapSet.new()

    unreachable =
      graph.nodes
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(graph.finish_points, &1))
      |> Enum.reject(&MapSet.member?(reachable, &1))
      |> Enum.sort()

    if unreachable == [], do: nil, else: unreachable
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
      |> traverse(reverse)
      |> MapSet.new()

    dead =
      graph.nodes
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(can_finish, &1))
      |> Enum.reject(&Map.has_key?(graph.conditional_edges, &1))
      |> Enum.reject(&Map.has_key?(graph.guarded_edges, &1))
      |> Enum.sort()

    if dead == [], do: nil, else: dead
  end

  defp traverse(starts, graph_or_adjacency) do
    adjacency =
      if is_map(graph_or_adjacency) and Map.has_key?(graph_or_adjacency, :nodes),
        do: adjacency(graph_or_adjacency),
        else: graph_or_adjacency

    do_traverse(List.wrap(starts), adjacency, [])
  end

  defp do_traverse([], _adjacency, seen), do: Enum.reverse(seen)

  defp do_traverse([node | rest], adjacency, seen) do
    if node in seen do
      do_traverse(rest, adjacency, seen)
    else
      do_traverse(Map.get(adjacency, node, []) ++ rest, adjacency, [node | seen])
    end
  end

  defp adjacency(graph) do
    conditional =
      graph.conditional_edges
      |> Enum.map(fn {source, spec} ->
        targets =
          spec.path_map
          |> Map.values()
          |> Kernel.++(List.wrap(spec.then))
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&(&1 == "__end__"))

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
  end

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
    invalid =
      graph.managed
      |> Enum.reject(fn {_key, managed} -> valid_managed?(managed) end)
      |> Enum.map(fn {key, managed} -> %{key: key, managed: inspect(managed)} end)

    if invalid == [], do: nil, else: invalid
  end

  defp valid_managed?(%{__struct__: module}) do
    Code.ensure_loaded?(module) and function_exported?(module, :get, 2)
  end

  defp valid_managed?(_managed), do: false

  defp valid_channel?(%{__struct__: module}) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :update, 2) and
      function_exported?(module, :get, 1) and
      function_exported?(module, :checkpoint, 1) and
      function_exported?(module, :from_checkpoint, 2) and
      function_exported?(module, :copy, 1) and
      function_exported?(module, :available?, 1)
  end

  defp valid_channel?(_channel), do: false

  defp inspect_callable(callable) when is_function(callable) do
    {:arity, arity} = :erlang.fun_info(callable, :arity)
    "function/#{arity}"
  end

  defp inspect_callable(callable), do: inspect(callable)
end
