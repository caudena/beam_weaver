defmodule BeamWeaver.Stream.SubgraphsTest do
  use ExUnit.Case, async: true

  # Native coverage for:

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Subgraphs

  test "subgraph projection creates direct-child summaries with trigger ids and completed status" do
    events = [
      task(:start, [], "agent", "abc"),
      value(["agent:abc"], %{x: 1}, graph: "AgentGraph"),
      task(:finish, ["agent:abc"], "tool", "t1", payload: %{x: 1})
    ]

    assert [
             %{
               path: ["agent:abc"],
               graph: "AgentGraph",
               graph_name: "agent",
               trigger_call_id: "abc",
               status: :completed,
               error: nil,
               values: [%{x: 1}],
               tasks: [%{kind: :finish, node: "tool", payload: %{x: 1}}]
             }
           ] = Subgraphs.from_events(events)
  end

  test "subgraph projection marks failed and interrupted terminal states" do
    failed =
      Subgraphs.from_events([
        error(["agent:abc"], Error.new(:node_exception, "boom"))
      ])

    assert [%{status: :failed, error: "boom"}] = failed

    interrupted =
      Subgraphs.from_events([
        error(["agent:abc"], Error.new(:graph_interrupt, "pause"))
      ])

    assert [%{status: :interrupted, error: "pause"}] = interrupted
  end

  test "subgraph projection nests grandchildren under child summaries" do
    events = [
      value(["agent:abc"], %{child: true}),
      value(["agent:abc", "tool:def"], %{grandchild: true})
    ]

    assert [
             %{
               path: ["agent:abc"],
               values: [%{child: true}],
               subgraphs: [%{path: ["agent:abc", "tool:def"], values: [%{grandchild: true}]}]
             }
           ] = Subgraphs.from_events(events)

    assert ["agent:abc", "tool:def"] in (events
                                         |> Subgraphs.from_events()
                                         |> Subgraphs.flatten()
                                         |> Enum.map(& &1.path))
  end

  test "real graph event streams expose child and grandchild subgraph summaries" do
    graph = two_level_nested_graph()

    assert {:ok, events} = Compiled.stream_events(graph, %{value: "x", items: []})

    assert [
             %{
               path: ["middle"],
               status: :completed,
               values: [_middle_value | _],
               subgraphs: [
                 %{
                   path: ["middle", "inner"],
                   status: :completed,
                   values: [%{items: ["x"], value: "x!"}]
                 }
               ]
             }
           ] = Subgraphs.from_events(events)
  end

  test "sibling subgraph summaries keep each sibling output without drain coupling" do
    graph = sibling_subgraphs()

    assert {:ok, events} = Compiled.stream_events(graph, %{value: "x", items: []})

    runs = events |> Subgraphs.from_events() |> Enum.sort_by(& &1.path)

    assert Enum.map(runs, & &1.path) == [["one"], ["two"]]
    assert [%{items: ["one"], value: "x"}] = Enum.at(runs, 0).values
    assert [%{items: ["two"], value: "x"}] = Enum.at(runs, 1).values
  end

  test "Task-backed async stream event projection returns the same subgraph hierarchy" do
    graph = two_level_nested_graph()

    assert {:ok, events} =
             graph
             |> Compiled.async_stream_events(%{value: "x", items: []})
             |> Async.await()

    assert [%{path: ["middle"], subgraphs: [%{path: ["middle", "inner"]}]}] =
             Subgraphs.from_events(events)
  end

  defp task(kind, namespace, node, task_id, opts \\ []) do
    Stream.envelope(
      %Events.Task{
        kind: kind,
        node: node,
        task_id: task_id,
        path: node,
        payload: Keyword.get(opts, :payload, %{})
      },
      namespace: namespace,
      graph: Keyword.get(opts, :graph)
    )
  end

  defp value(namespace, value, opts \\ []) do
    Stream.envelope(%Events.GraphValue{value: value},
      namespace: namespace,
      graph: Keyword.get(opts, :graph)
    )
  end

  defp error(namespace, error) do
    Stream.envelope(%Events.Error{error: error}, namespace: namespace)
  end

  defp two_level_nested_graph do
    inner =
      Graph.new(name: "InnerGraph")
      |> Graph.add_node(:inner_node, &passthrough/1)
      |> Graph.add_edge(Graph.start(), :inner_node)
      |> Graph.add_edge(:inner_node, Graph.end_node())
      |> Graph.compile!()

    middle =
      Graph.new(name: "MiddleGraph")
      |> Graph.add_node(:inner, inner)
      |> Graph.add_edge(Graph.start(), :inner)
      |> Graph.add_edge(:inner, Graph.end_node())
      |> Graph.compile!()

    Graph.new(name: "OuterGraph")
    |> Graph.add_node(:middle, middle)
    |> Graph.add_edge(Graph.start(), :middle)
    |> Graph.add_edge(:middle, Graph.end_node())
    |> Graph.compile!()
  end

  defp sibling_subgraphs do
    one =
      Graph.new(name: "OneGraph")
      |> Graph.add_node(:add_one, fn _state -> %{items: ["one"]} end)
      |> Graph.add_edge(Graph.start(), :add_one)
      |> Graph.add_edge(:add_one, Graph.end_node())
      |> Graph.compile!()

    two =
      Graph.new(name: "TwoGraph")
      |> Graph.add_node(:add_two, fn _state -> %{items: ["two"]} end)
      |> Graph.add_edge(Graph.start(), :add_two)
      |> Graph.add_edge(:add_two, Graph.end_node())
      |> Graph.compile!()

    Graph.new(name: "OuterGraph")
    |> Graph.add_node(:one, one)
    |> Graph.add_node(:two, two)
    |> Graph.add_edge(:one, :two)
    |> Graph.add_edge(Graph.start(), :one)
    |> Graph.add_edge(:two, Graph.end_node())
    |> Graph.compile!()
  end

  defp passthrough(state) do
    %{value: state.value <> "!", items: ["x"]}
  end
end
