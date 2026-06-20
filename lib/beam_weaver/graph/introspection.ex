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
      input_channels: input_channels(graph),
      output_channels: output_channels(graph),
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
      graph.edges
      |> Enum.flat_map(fn {source, targets} ->
        Enum.map(
          targets,
          &%{source: source, target: &1, kind: :edge, conditional: false, data: nil}
        )
      end)

    guarded =
      graph.guarded_edges
      |> Enum.flat_map(fn {source, specs} ->
        Enum.map(specs, fn spec ->
          %{
            source: source,
            target: spec.target,
            kind: :guarded,
            conditional: true,
            data: %{
              when: spec.match,
              max_runs: spec.max_runs,
              default: spec.default?
            }
          }
        end)
      end)

    destinations =
      graph.nodes
      |> Enum.flat_map(fn {source, spec} ->
        destination_edges(source, spec.destinations)
      end)

    (explicit ++ guarded ++ destinations)
    |> Enum.sort_by(&{&1.source, &1.target})
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

  defp input_channels(graph) do
    graph.input_schema
    |> schema_keys()
    |> case do
      [] ->
        graph.channels
        |> Map.keys()
        |> Enum.reject(&(Map.get(graph.channel_visibility, &1, :public) == :private or internal_channel?(&1)))
        |> Enum.map(&to_string/1)
        |> Enum.sort()

      keys ->
        keys
    end
  end

  defp output_channels(graph) do
    public =
      graph.channels
      |> Map.keys()
      |> Enum.reject(&(Map.get(graph.channel_visibility, &1, :public) == :private or internal_channel?(&1)))
      |> Enum.map(&to_string/1)

    graph.output_schema
    |> schema_keys()
    |> case do
      [] -> Enum.sort(public)
      keys -> keys
    end
  end

  defp hidden_channels(graph) do
    graph.channels
    |> Map.keys()
    |> Enum.filter(&(Map.get(graph.channel_visibility, &1, :public) == :private or internal_channel?(&1)))
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp managed_metadata(graph) do
    Map.new(graph.managed, fn {key, managed} ->
      {to_string(key), %{module: managed.__struct__}}
    end)
  end

  defp subgraphs(graph) do
    graph.nodes
    |> Enum.filter(fn {_name, spec} -> spec.kind in [:subgraph, :agent] end)
    |> Map.new(fn {name, spec} -> {name, spec.metadata} end)
  end

  defp schema_keys(nil), do: []

  defp schema_keys(schema) when is_map(schema),
    do: schema |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  defp schema_keys(_schema), do: []

  defp internal_channel?(key), do: to_string(key) in ["__node_outputs__", "__edge_runs__"]
end

defmodule BeamWeaver.Graph.Renderer do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Introspection

  @spec to_mermaid(Introspection.t(), keyword()) :: String.t()
  def to_mermaid(%Introspection{} = graph, _opts \\ []) do
    node_lines =
      graph.nodes
      |> Enum.sort_by(fn {name, _node} -> name end)
      |> Enum.map(fn {name, node} -> "  #{node_id(name)}[\"#{escape(name)}:#{node.kind}\"]" end)

    edge_lines =
      graph.edges
      |> Enum.map(fn edge -> "  #{node_id(edge.source)} --> #{node_id(edge.target)}" end)

    branch_lines =
      graph.branches
      |> Enum.flat_map(fn branch ->
        Enum.map(branch.path_map, fn {route, target} ->
          "  #{node_id(branch.source)} -- \"#{escape(route)}\" --> #{node_id(target)}"
        end)
      end)

    waiting_lines =
      graph.waiting_edges
      |> Enum.flat_map(fn waiting ->
        Enum.map(waiting.upstream, fn upstream ->
          "  #{node_id(upstream)} -. \"wait:#{escape(waiting.id)}\" .-> #{node_id(waiting.target)}"
        end)
      end)

    Enum.join(["graph TD" | node_lines ++ edge_lines ++ branch_lines ++ waiting_lines], "\n")
  end

  @spec to_ascii(Introspection.t(), keyword()) :: String.t()
  def to_ascii(%Introspection{} = graph, _opts \\ []) do
    edge_lines = Enum.map(graph.edges, &"#{&1.source} -> #{&1.target}")

    branch_lines =
      Enum.flat_map(graph.branches, fn branch ->
        Enum.map(branch.path_map, fn {route, target} ->
          "#{branch.source} -[#{route}]-> #{target}"
        end)
      end)

    waiting_lines =
      Enum.flat_map(graph.waiting_edges, fn waiting ->
        Enum.map(waiting.upstream, &"#{&1} -[wait:#{waiting.id}]-> #{waiting.target}")
      end)

    case edge_lines ++ branch_lines ++ waiting_lines do
      [] -> graph.nodes |> Map.keys() |> Enum.sort() |> Enum.join("\n")
      lines -> lines |> Enum.sort() |> Enum.join("\n")
    end
  end

  @spec to_png(Introspection.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def to_png(%Introspection{} = graph, opts \\ []) do
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
