defmodule BeamWeaver.Graph.Introspection do
  @moduledoc """
  Public graph introspection data.

  The struct is plain data so it can be rendered, tested, serialized, or used by
  documentation tooling without reaching into graph execution runtime internals.
  """

  alias BeamWeaver.Graph.Compiled

  defstruct [
    :name,
    nodes: %{},
    edges: [],
    branches: [],
    waiting_edges: [],
    channels: %{},
    input_channels: [],
    output_channels: [],
    hidden_channels: [],
    managed: %{},
    subgraphs: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec from_compiled(Compiled.t(), keyword()) :: t()
  def from_compiled(%Compiled{} = compiled, opts \\ []) do
    graph = compiled.graph

    %__MODULE__{
      name: compiled.name,
      nodes: node_metadata(graph),
      edges: edge_metadata(graph),
      branches: branch_metadata(graph),
      waiting_edges: waiting_edge_metadata(graph),
      channels: channel_metadata(graph),
      input_channels: schema_or_public_channels(graph, graph.input_schema),
      output_channels: schema_or_public_channels(graph, graph.output_schema),
      hidden_channels: hidden_channels(graph),
      managed: managed_metadata(graph),
      subgraphs: subgraphs(graph),
      metadata: Map.merge(%{debug: compiled.debug}, Keyword.get(opts, :metadata, %{}))
    }
  end

  defp node_metadata(graph) do
    Map.new(graph.nodes, fn {name, spec} ->
      {name,
       %{
         name: name,
         kind: spec.kind,
         input: spec.input,
         output: spec.output,
         destinations: spec.destinations,
         metadata: spec.metadata,
         defer: spec.defer,
         triggers: spec.triggers,
         retry: spec.retry_policy,
         timeout: spec.execution_policy,
         cache: spec.cache_policy || spec.cache
       }}
    end)
  end

  defp edge_metadata(graph) do
    explicit =
      for {source, targets} <- graph.edges,
          target <- targets,
          do: %{source: source, target: target, kind: :edge, conditional: false, data: nil}

    guarded =
      for {source, specs} <- graph.guarded_edges, spec <- specs do
        data = %{when: spec.match, max_runs: spec.max_runs, default: spec.default?}
        %{source: source, target: spec.target, kind: :guarded, conditional: true, data: data}
      end

    destinations = Enum.flat_map(graph.nodes, fn {source, spec} -> destination_edges(source, spec.destinations) end)

    Enum.sort_by(explicit ++ guarded ++ destinations, &{&1.source, &1.target})
  end

  defp destination_edges(_source, destinations) when destinations in [nil, [], %{}], do: []

  defp destination_edges(source, destinations) when is_map(destinations) do
    Enum.map(destinations, fn {target, label} ->
      %{source: source, target: target, kind: :destination, conditional: true, data: label}
    end)
  end

  defp destination_edges(source, destinations) do
    destinations
    |> List.wrap()
    |> Enum.map(&%{source: source, target: &1, kind: :destination, conditional: true, data: nil})
  end

  defp branch_metadata(graph) do
    graph.conditional_edges
    |> Enum.map(fn {source, spec} ->
      %{
        source: source,
        path_map: spec.path_map,
        then: Map.get(spec, :then),
        metadata: Map.get(spec, :metadata, %{})
      }
    end)
    |> Enum.sort_by(& &1.source)
  end

  defp waiting_edge_metadata(graph) do
    graph.waiting_edges
    |> Enum.map(fn spec ->
      %{
        id: spec.id,
        channel: spec.channel,
        upstream: spec.upstream,
        target: spec.target,
        metadata: spec.metadata
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp channel_metadata(graph) do
    Map.new(graph.channels, fn {key, channel} ->
      {to_string(key),
       %{
         key: key,
         module: channel.__struct__,
         visibility: Map.get(graph.channel_visibility, key, :public),
         subscribers: Map.get(graph.channel_subscriptions, to_string(key), [])
       }}
    end)
  end

  # The keys of the schema, or every channel callers see when it has none.
  defp schema_or_public_channels(graph, schema) do
    case schema_keys(schema) do
      [] -> Enum.sort(for key <- Map.keys(graph.channels), not hidden_channel?(graph, key), do: to_string(key))
      keys -> keys
    end
  end

  defp hidden_channels(graph),
    do: Enum.sort(for key <- Map.keys(graph.channels), hidden_channel?(graph, key), do: to_string(key))

  defp hidden_channel?(graph, key) do
    Map.get(graph.channel_visibility, key, :public) in [:private, :private_checkpointed] or
      internal_channel?(key)
  end

  defp managed_metadata(graph) do
    Map.new(graph.managed, fn {key, managed} ->
      {to_string(key), %{module: managed.__struct__}}
    end)
  end

  defp subgraphs(graph), do: for({name, %{kind: :subgraph} = spec} <- graph.nodes, into: %{}, do: {name, spec.metadata})

  defp schema_keys(schema) when is_map(schema),
    do: schema |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  defp schema_keys(_schema), do: []

  defp internal_channel?(key) do
    key = to_string(key)
    key in ["__node_outputs__", "__edge_runs__"] or String.starts_with?(key, "__barrier__:")
  end
end

defmodule BeamWeaver.Graph.Renderer do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Introspection

  @spec to_mermaid(Introspection.t(), keyword()) :: String.t()
  def to_mermaid(%Introspection{} = graph, _opts) do
    node_lines =
      graph.nodes
      |> Enum.sort_by(fn {name, _node} -> name end)
      |> Enum.map(fn {name, node} -> "  #{node_id(name)}[\"#{escape(name)}:#{node.kind}\"]" end)

    edge_lines = for edge <- graph.edges, do: "  #{node_id(edge.source)} --> #{node_id(edge.target)}"

    branch_lines =
      for branch <- graph.branches,
          {route, target} <- branch.path_map,
          do: "  #{node_id(branch.source)} -- \"#{escape(route)}\" --> #{node_id(target)}"

    waiting_lines =
      for waiting <- graph.waiting_edges,
          upstream <- waiting.upstream,
          do: "  #{node_id(upstream)} -. \"wait:#{escape(waiting.id)}\" .-> #{node_id(waiting.target)}"

    Enum.join(["graph TD" | node_lines ++ edge_lines ++ branch_lines ++ waiting_lines], "\n")
  end

  @spec to_ascii(Introspection.t(), keyword()) :: String.t()
  def to_ascii(%Introspection{} = graph, _opts) do
    edge_lines = Enum.map(graph.edges, &"#{&1.source} -> #{&1.target}")

    branch_lines =
      for branch <- graph.branches, {route, target} <- branch.path_map, do: "#{branch.source} -[#{route}]-> #{target}"

    waiting_lines =
      for waiting <- graph.waiting_edges,
          upstream <- waiting.upstream,
          do: "#{upstream} -[wait:#{waiting.id}]-> #{waiting.target}"

    case edge_lines ++ branch_lines ++ waiting_lines do
      [] -> graph.nodes |> Map.keys() |> Enum.sort() |> Enum.join("\n")
      lines -> lines |> Enum.sort() |> Enum.join("\n")
    end
  end

  @spec to_png(Introspection.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def to_png(%Introspection{} = graph, opts) do
    case Keyword.get(opts, :renderer) do
      renderer when is_function(renderer, 1) -> {:ok, renderer.(to_mermaid(graph, opts))}
      nil -> {:error, Error.new(:png_renderer_not_configured, "PNG renderer is not configured")}
    end
  end

  defp node_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "node"
      id -> id
    end
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("\"", "\\\"")
  end
end
