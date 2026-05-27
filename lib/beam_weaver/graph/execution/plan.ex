defmodule BeamWeaver.Graph.Execution.Plan do
  @moduledoc false

  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.TaskRequest

  @start "__start__"

  defstruct [
    :graph,
    triggers_by_channel: %{},
    entry_requests: [],
    branch_channels: [],
    channel_subscriptions: %{},
    finish_nodes: MapSet.new()
  ]

  @type t :: %__MODULE__{}

  @spec from(map()) :: t()
  def from(graph) do
    branch_edges =
      graph.edges
      |> Enum.flat_map(fn {source, targets} ->
        Enum.map(targets, fn target -> {branch_channel(source, target), to_string(target)} end)
      end)

    entry_edges = Enum.map(graph.entry_points, &{branch_channel(@start, &1), to_string(&1)})

    conditional_edges =
      graph.conditional_edges
      |> Enum.flat_map(fn {source, %{path_map: path_map}} ->
        Enum.map(path_map, fn {_path, target} ->
          {branch_channel(source, target), to_string(target)}
        end)
      end)

    state_channels =
      graph.nodes
      |> Enum.flat_map(fn {node, spec} ->
        spec
        |> Map.get(:triggers, [])
        |> Enum.map(&{to_string(&1), to_string(node)})
      end)

    schema_channels =
      graph
      |> Map.get(:channel_subscriptions, %{})
      |> Enum.flat_map(fn {channel, nodes} ->
        Enum.map(nodes, &{to_string(channel), to_string(&1)})
      end)

    waiting_channels =
      graph
      |> Map.get(:waiting_edges, [])
      |> Enum.map(fn spec -> {to_string(spec.channel), to_string(spec.target)} end)

    trigger_edges =
      branch_edges ++
        conditional_edges ++
        entry_edges ++
        state_channels ++
        schema_channels ++
        waiting_channels

    %__MODULE__{
      graph: graph,
      triggers_by_channel:
        trigger_edges
        |> Enum.group_by(fn {channel, _node} -> channel end, fn {_channel, node} -> node end)
        |> Map.new(fn {channel, nodes} -> {channel, Enum.uniq(nodes)} end),
      entry_requests:
        Enum.map(graph.entry_points, fn node ->
          TaskRequest.pull(node, [branch_channel(@start, node)])
        end),
      branch_channels:
        trigger_edges
        |> Enum.map(fn {channel, _node} -> channel end)
        |> Execution.normalize_channels(),
      channel_subscriptions: Map.get(graph, :channel_subscriptions, %{}),
      finish_nodes: graph.finish_points
    }
  end

  @spec branch_channel(atom() | String.t(), atom() | String.t()) :: String.t()
  def branch_channel(source, target),
    do: "__branch__:" <> to_string(source) <> ":" <> to_string(target)
end
