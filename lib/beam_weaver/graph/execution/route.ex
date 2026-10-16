defmodule BeamWeaver.Graph.Execution.Route do
  @moduledoc false

  # Where a finished task sends the run: its node, whose edges the scheduler
  # follows, the nodes its `Command` names in `goto` (they replace that node's
  # edges), the `Send`s it returned, and its output, which guarded edges and
  # conditional `deps:` match on. A step routes from all of its tasks when it
  # completes. When a step stops partway, on an error or an interrupt, each
  # finished task's route is saved with its writes under `channel/0`, so the
  # step still routes from those tasks when the thread continues.

  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.Send

  @channel "__route__"
  @tasks "__tasks__"

  defstruct [:node, goto: [], sends: [], outputs: %{}]

  @type t :: %__MODULE__{
          node: String.t(),
          goto: [String.t()],
          sends: [TaskRequest.t()],
          outputs: map()
        }

  @spec channel() :: String.t()
  def channel, do: @channel

  # A finished task's route from its normalized result.
  @spec new(String.t(), map()) :: t()
  def new(node, normalized) do
    %__MODULE__{
      node: to_string(node),
      goto: normalized |> Map.get(:next, []) |> Enum.map(&to_string/1),
      sends: normalized |> Map.get(:sends, []) |> Enum.map(&send_request/1),
      outputs: normalized |> Map.get(:updates, []) |> Enum.find_value(%{}, &Map.get(&1, :__node_outputs__))
    }
  end

  @spec send_request(Send.t() | TaskRequest.t()) :: TaskRequest.t()
  def send_request(%TaskRequest{} = request), do: request

  def send_request(%Send{} = send),
    do: TaskRequest.send(send.node, send.update || %{}, [@tasks], timeout: send.timeout)

  # The route as a pending write saves it. The output is kept only when the
  # node's routing reads it.
  @spec encode(t(), map()) :: map()
  def encode(%__MODULE__{} = route, graph) do
    put_output(
      %{
        "node" => route.node,
        "goto" => route.goto,
        "sends" => Enum.map(route.sends, &TaskRequest.checkpoint_record(&1, graph))
      },
      route,
      graph
    )
  end

  defp put_output(record, %__MODULE__{node: node, outputs: outputs}, graph) do
    with true <- reads_output?(graph, node),
         {:ok, output} <- Map.fetch(outputs, node) do
      Map.put(record, "output", output)
    else
      _skip -> record
    end
  end

  # The routes saved in a checkpoint's pending writes.
  @spec from_writes(list()) :: [t()]
  def from_writes(pending_writes) do
    Enum.flat_map(pending_writes, fn
      {_task_id, @channel, value} -> [decode(value)]
      {_task_id, @channel, value, _path} -> [decode(value)]
      _other -> []
    end)
  end

  defp decode(%__MODULE__{} = route), do: route

  defp decode(%{"node" => node} = value) do
    node = to_string(node)

    %__MODULE__{
      node: node,
      goto: value |> Map.get("goto", []) |> Enum.map(&to_string/1),
      sends: value |> Map.get("sends", []) |> Enum.map(&TaskRequest.from_checkpoint/1),
      outputs: decode_outputs(node, value)
    }
  end

  # Routes saved before map keys kept their types name the output's atom keys
  # in "atom_keys".
  defp decode_outputs(node, %{"output" => output} = value) when is_map(output) and not is_struct(output),
    do: %{node => ChannelLookup.restore_atom_keys(output, Map.get(value, "atom_keys"))}

  defp decode_outputs(node, %{"output" => output}), do: %{node => output}
  defp decode_outputs(_node, _value), do: %{}

  # The state to route with: it holds the outputs of the routes' nodes, as
  # it does for the nodes that ran in the step.
  @spec put_outputs(map(), [t()], map()) :: map()
  def put_outputs(state, routes, graph) do
    case Enum.reduce(routes, %{}, &Map.merge(&2, &1.outputs)) do
      outputs when outputs == %{} -> state
      outputs -> ChannelMerge.merge_update(state, %{__node_outputs__: outputs}, graph)
    end
  end

  # Nodes whose routing reads their output: sources of guarded edges, and the
  # nodes that a `deps:` node with a condition waits on.
  defp reads_output?(graph, node) do
    Map.has_key?(graph.guarded_edges, node) or
      Enum.any?(graph.nodes, fn {_name, spec} -> spec.condition && node in spec.deps end)
  end
end
