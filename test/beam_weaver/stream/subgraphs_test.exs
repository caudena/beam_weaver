defmodule BeamWeaver.Stream.SubgraphsTest do
  use ExUnit.Case, async: true

  # Native coverage for:

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
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

  describe "a subgraph's status in a graph's stream" do
    test "is :failed with its error when the subgraph fails, and the run's own Error is the only one" do
      graph = with_node(:check, failing("the amount must be positive"))

      events = live_events(graph)

      assert [%{path: ["check"], status: :failed, error: "the amount must be positive"}] =
               Subgraphs.from_events(events)

      assert [%Envelope{namespace: [], node: nil}] = Enum.filter(events, &match?(%Envelope{event: %Events.Error{}}, &1))
    end

    test "is :failed for each subgraph around a nested subgraph that fails" do
      graph = with_node(:middle, with_node(:inner, failing("boom")))

      assert [{["middle"], :failed, "boom"}, {["middle", "inner"], :failed, "boom"}] =
               graph
               |> live_events()
               |> Subgraphs.from_events()
               |> Subgraphs.flatten()
               |> Enum.map(&{&1.path, &1.status, &1.error})
    end

    test "is :completed when the node's retry ran the subgraph again and it succeeded" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      flaky =
        Graph.new(name: "FlakyGraph")
        |> Graph.add_node(:work, fn _state ->
          if Agent.get_and_update(attempts, &{&1, &1 + 1}) == 0, do: {:error, "first try fails"}, else: %{value: "done"}
        end)
        |> Graph.add_edge(Graph.start(), :work)
        |> Graph.add_edge(:work, Graph.end_node())
        |> Graph.compile!()

      graph = with_node(:flaky, flaky, retry: [max_attempts: 2])

      assert {:ok, events} = Compiled.stream_events(graph, %{value: "x"})
      assert [%{path: ["flaky"], status: :completed, error: nil}] = Subgraphs.from_events(events)
    end

    test "is :completed when the node's error handler handled the failure" do
      graph = with_node(:check, failing("boom"), error_handler: fn _error, _state, _runtime -> %{value: "handled"} end)

      assert {:ok, events} = Compiled.stream_events(graph, %{value: "x"})
      assert [%{path: ["check"], status: :completed}] = Subgraphs.from_events(events)
    end

    test "is :interrupted when the subgraph pauses" do
      ask =
        Graph.new(name: "AskGraph")
        |> Graph.add_node(:ask, fn _state -> %{value: Graph.interrupt("Approve the refund?")} end)
        |> Graph.add_edge(Graph.start(), :ask)
        |> Graph.add_edge(:ask, Graph.end_node())
        |> Graph.compile!()

      graph =
        Graph.new(name: "OuterGraph")
        |> Graph.add_node(:review, ask)
        |> Graph.add_edge(Graph.start(), :review)
        |> Graph.add_edge(:review, Graph.end_node())
        |> Graph.compile!(checkpointer: BeamWeaver.Checkpoint.ETS.new())

      assert {:interrupted, %{events: events}} =
               Compiled.stream_events(graph, %{value: "x"}, config: %{"configurable" => %{"thread_id" => "refund-1"}})

      assert [%{path: ["review"], status: :interrupted, error: nil}] = Subgraphs.from_events(events)
    end
  end

  test "sibling subgraph summaries keep each sibling output without drain coupling" do
    graph = sibling_subgraphs()

    assert {:ok, events} = Compiled.stream_events(graph, %{value: "x", items: []})

    runs = events |> Subgraphs.from_events() |> Enum.sort_by(& &1.path)

    assert Enum.map(runs, & &1.path) == [["one"], ["two"]]
    assert [%{items: ["one"], value: "x"}] = Enum.at(runs, 0).values
    assert [%{items: ["two"], value: "x"}] = Enum.at(runs, 1).values
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

  # A graph that runs `subgraph` as its one node.
  defp with_node(name, subgraph, opts \\ []) do
    Graph.new(name: "#{name}_parent")
    |> Graph.add_node(name, subgraph, opts)
    |> Graph.add_edge(Graph.start(), name)
    |> Graph.add_edge(name, Graph.end_node())
    |> Graph.compile!()
  end

  defp failing(reason) do
    Graph.new(name: "FailingGraph")
    |> Graph.add_node(:check_amount, fn _state -> {:error, reason} end)
    |> Graph.add_edge(Graph.start(), :check_amount)
    |> Graph.add_edge(:check_amount, Graph.end_node())
    |> Graph.compile!()
  end

  # The events of a run that may fail: a collected stream returns only the
  # error.
  defp live_events(graph) do
    assert {:ok, events} = Compiled.stream_events(graph, %{value: "x"}, live: true)
    Enum.to_list(events)
  end
end
