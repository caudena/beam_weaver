defmodule BeamWeaver.Graph.Execution.Plan do
  @moduledoc false

  alias BeamWeaver.Graph.Execution.TaskRequest

  @start "__start__"

  defstruct [:graph, triggers_by_channel: %{}, entry_requests: []]

  @type t :: %__MODULE__{}

  @spec from(map()) :: t()
  def from(graph) do
    trigger_edges =
      for({source, targets} <- graph.edges, target <- targets, do: {branch_channel(source, target), to_string(target)}) ++
        for(
          {source, %{path_map: path_map}} <- graph.conditional_edges,
          {_path, target} <- path_map,
          do: {branch_channel(source, target), to_string(target)}
        ) ++
        Enum.map(graph.entry_points, &{branch_channel(@start, &1), to_string(&1)}) ++
        for({node, spec} <- graph.nodes, trigger <- spec.triggers, do: {to_string(trigger), to_string(node)}) ++
        for({channel, nodes} <- graph.channel_subscriptions, node <- nodes, do: {to_string(channel), to_string(node)}) ++
        Enum.map(graph.waiting_edges, &{to_string(&1.channel), to_string(&1.target)})

    %__MODULE__{
      graph: graph,
      triggers_by_channel:
        trigger_edges
        |> Enum.group_by(fn {channel, _node} -> channel end, fn {_channel, node} -> node end)
        |> Map.new(fn {channel, nodes} -> {channel, Enum.uniq(nodes)} end),
      entry_requests: Enum.map(graph.entry_points, &TaskRequest.pull(&1, [branch_channel(@start, &1)]))
    }
  end

  @spec branch_channel(atom() | String.t(), atom() | String.t()) :: String.t()
  def branch_channel(source, target),
    do: "__branch__:" <> to_string(source) <> ":" <> to_string(target)
end
