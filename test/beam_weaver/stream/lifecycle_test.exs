defmodule BeamWeaver.StreamLifecycleTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Lifecycle
  alias BeamWeaver.Stream.Transformers

  test "projects subgraph runs into lifecycle envelopes" do
    events = [
      task(:start, [], "agent", "abc"),
      value(["agent:abc"], %{x: 1}, graph: "AgentGraph", run_id: "run-child"),
      task(:finish, ["agent:abc"], "tool", "t1", payload: %{x: 1})
    ]

    assert [
             %Envelope{
               event: %Events.Lifecycle{
                 status: :started,
                 namespace: ["agent:abc"],
                 graph_name: "agent",
                 trigger_call_id: "abc"
               },
               run_id: "run-child",
               namespace: ["agent:abc"]
             },
             %Envelope{
               event: %Events.Lifecycle{
                 status: :completed,
                 namespace: ["agent:abc"],
                 error: nil
               }
             }
           ] = Lifecycle.from_events(events)
  end

  test "projects failed and interrupted terminal lifecycle states" do
    failed =
      Lifecycle.from_events([
        Stream.envelope(%Events.Error{error: Error.new(:node_exception, "boom")},
          namespace: ["agent:abc"]
        )
      ])

    assert [%Envelope{event: %Events.Lifecycle{status: :started}}, failed_terminal] = failed
    assert %Envelope{event: %Events.Lifecycle{status: :failed, error: "boom"}} = failed_terminal

    interrupted =
      Lifecycle.from_events([
        Stream.envelope(%Events.Error{error: Error.new(:graph_interrupt, "pause")},
          namespace: ["agent:abc"]
        )
      ])

    assert [%Envelope{event: %Events.Lifecycle{status: :started}}, interrupted_terminal] =
             interrupted

    assert %Envelope{event: %Events.Lifecycle{status: :interrupted, error: "pause"}} =
             interrupted_terminal
  end

  test "lifecycle envelopes participate in native stream transformers" do
    events = Lifecycle.from_events([value(["agent:abc"], %{x: 1})])

    assert [
             {:lifecycle, %Envelope{event: %Events.Lifecycle{status: :started}}},
             {:lifecycle, %Envelope{event: %Events.Lifecycle{status: :completed}}}
           ] =
             Transformers.stream(events, :lifecycle, scope: ["agent:abc"]) |> Enum.to_list()
  end

  test "real graph streams can be summarized into lifecycle events" do
    graph = nested_graph()

    assert {:ok, events} = Compiled.stream_events(graph, %{value: "x", items: []})

    lifecycle = Lifecycle.from_events(events)

    assert Enum.any?(
             lifecycle,
             &match?(
               %Envelope{
                 event: %Events.Lifecycle{status: :started, namespace: ["middle"]}
               },
               &1
             )
           )

    assert Enum.any?(
             lifecycle,
             &match?(
               %Envelope{
                 event: %Events.Lifecycle{status: :completed, namespace: ["middle", "inner"]}
               },
               &1
             )
           )

    assert {:ok, async_events} =
             graph
             |> Compiled.async_stream_events(%{value: "x", items: []})
             |> Async.await()

    assert length(Lifecycle.from_events(async_events)) == length(lifecycle)
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
      graph: Keyword.get(opts, :graph),
      run_id: Keyword.get(opts, :run_id)
    )
  end

  defp value(namespace, value, opts \\ []) do
    Stream.envelope(%Events.GraphValue{value: value},
      namespace: namespace,
      graph: Keyword.get(opts, :graph),
      run_id: Keyword.get(opts, :run_id)
    )
  end

  defp nested_graph do
    inner =
      Graph.new(name: "InnerGraph")
      |> Graph.add_node(:inner_node, fn state -> %{value: state.value <> "!", items: ["x"]} end)
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
end
