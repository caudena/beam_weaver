defmodule BeamWeaver.Graph.StreamEventsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up the shipping status of an order by its id."

    schema do
      field :order_id, :string, description: "The order id"
    end

    @impl true
    def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
  end

  defmodule SupportAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      stream: true,
      responses: [
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
        "Your order A-1001 shipped on Monday."
      ]

    tools [BeamWeaver.Graph.StreamEventsTest.LookupOrder]
  end

  @question %{messages: ["Where is my order A-1001?"]}

  describe "collected and live streams" do
    test "a graph run has the same events in the same order" do
      graph = triage_graph()

      assert {:ok, collected} = Compiled.stream_events(graph, %{subject: "Refund for A-1001"})
      assert {:ok, live} = Compiled.stream_events(graph, %{subject: "Refund for A-1001"}, live: true)

      assert signatures(collected) == signatures(Enum.to_list(live))

      assert [{[], ["classify"]}, {["billing"], ["reply"]}, {[], ["billing"]}] =
               for(
                 %Envelope{event: %Events.GraphUpdate{update: update}} = envelope <- collected,
                 do: {envelope.namespace, Map.keys(update)}
               )

      assert [%{stage: :classifying}, %{stage: :replying}] =
               for(%Envelope{event: %Events.Custom{payload: payload}} <- collected, do: payload)
    end

    test "an agent run with a streamed model and a tool call has the same events in the same order" do
      assert {:ok, collected} = SupportAgent.stream_events(@question)
      assert {:ok, live} = SupportAgent.stream_events(@question, live: true)

      assert signatures(collected) == signatures(Enum.to_list(live))

      assert ["Debug producer_start" | _] = Enum.map(collected, &label/1)
      assert "Debug producer_stop" == collected |> List.last() |> label()

      steps = for %Envelope{event: %Events.GraphUpdate{update: update}} <- collected, do: Map.keys(update)
      assert steps == [["model"], ["tools"], ["model"]]
    end

    test "a paused run returns the same events as the live stream" do
      graph =
        Graph.new(name: "PausedStream")
        |> Graph.add_node(:approve, fn _state -> %{approved: Graph.interrupt(:approve?)} end)
        |> Graph.add_edge(Graph.start(), :approve)
        |> Graph.add_edge(:approve, Graph.end_node())
        |> Graph.compile!(checkpointer: BeamWeaver.Checkpoint.ETS.new())

      config = fn thread -> [config: %{"configurable" => %{"thread_id" => thread}}] end

      assert {:interrupted, %{value: :approve?, events: collected}} =
               Compiled.stream_events(graph, %{}, config.("collected"))

      assert {:ok, live} = Compiled.stream_events(graph, %{}, [live: true] ++ config.("live"))

      assert signatures(collected) == signatures(Enum.to_list(live))
      assert Enum.any?(collected, &match?(%Envelope{event: %Events.Debug{payload: %{type: :interrupt}}}, &1))
    end
  end

  test "a collected stream keeps the model's typed events" do
    assert {:ok, events} = SupportAgent.stream_events(@question)

    assert ["Your ", "order ", "A-1001 ", "shipped ", "on ", "Monday."] ==
             for(%Envelope{event: %Events.Token{text: text}} <- events, do: text)

    assert Enum.any?(events, &match?(%Envelope{event: %Events.MessageChunk{}}, &1))
    assert [_tool_call_turn, _answer_turn] = for(%Envelope{event: %Events.Done{}} = done <- events, do: done)
    refute Enum.any?(events, &match?(%Envelope{event: %Events.Custom{}}, &1))
  end

  test "node events carry the node, and subgraph events the subgraph's namespace" do
    assert {:ok, stream} = Compiled.stream_events(triage_graph(), %{subject: "Refund for A-1001"}, live: true)
    events = Enum.to_list(stream)

    assert [
             %Envelope{node: "classify", namespace: []},
             %Envelope{node: "reply", namespace: ["billing"]}
           ] = for(%Envelope{event: %Events.Custom{}} = envelope <- events, do: envelope)

    assert [nil, nil, nil] == for(%Envelope{event: %Events.GraphValue{}} = envelope <- events, do: envelope.node)
  end

  test "a live stream sends each subgraph event once" do
    assert {:ok, live} = Compiled.stream_events(triage_graph(), %{subject: "Refund for A-1001"}, live: true)
    subgraph_events = live |> Enum.to_list() |> Enum.filter(&(&1.namespace == ["billing"]))

    assert Enum.map(subgraph_events, &label/1) == [
             "Custom",
             "Task start reply",
             "Task finish reply",
             "GraphUpdate",
             "GraphValue",
             "Checkpoint"
           ]
  end

  test "every event of a stream carries the run id" do
    graph = triage_graph()

    for opts <- [[], [live: true]] do
      assert {:ok, events} = Compiled.stream_events(graph, %{subject: "Refund"}, [run_id: "run-42"] ++ opts)

      assert events
             |> Enum.reject(&(&1.namespace == ["billing"]))
             |> Enum.all?(&(&1.run_id == "run-42"))
    end
  end

  describe "stream_mode" do
    test "keeps only the selected kinds of events, live or collected" do
      opts = [stream_mode: [:messages, :tools]]

      assert {:ok, collected} = SupportAgent.stream_events(@question, opts)
      assert {:ok, live} = SupportAgent.stream_events(@question, [live: true] ++ opts)

      assert signatures(collected) == signatures(Enum.to_list(live))
      assert Enum.all?(collected, &(Stream.event_mode(&1.event) in [:messages, :tools]))
      assert Enum.any?(collected, &match?(%Envelope{event: %Events.Token{}}, &1))
      assert Enum.any?(collected, &match?(%Envelope{event: %Events.ToolStart{}}, &1))
      assert Enum.any?(collected, &match?(%Envelope{event: %Events.Message{}}, &1))
    end

    test "applies to subgraph events" do
      assert {:ok, events} = Compiled.stream_events(triage_graph(), %{subject: "Refund"}, stream_mode: :updates)

      assert [{[], ["classify"]}, {["billing"], ["reply"]}, {[], ["billing"]}] ==
               Enum.map(events, fn %Envelope{event: %Events.GraphUpdate{update: update}} = envelope ->
                 {envelope.namespace, Map.keys(update)}
               end)
    end

    test "still ends a failed live run with its error" do
      graph =
        Graph.new(name: "FailingStream")
        |> Graph.add_node(:boom, fn _state -> {:error, Error.new(:boom, "it broke")} end)
        |> Graph.add_edge(Graph.start(), :boom)
        |> Graph.add_edge(:boom, Graph.end_node())
        |> Graph.compile!()

      assert {:ok, live} = Compiled.stream_events(graph, %{}, live: true, stream_mode: :updates)
      assert [%Envelope{event: %Events.Error{error: %Error{type: :boom}}}] = Enum.to_list(live)

      assert {:error, %Error{type: :boom}} = Compiled.stream_events(graph, %{}, stream_mode: :updates)
    end

    test "rejects unknown modes" do
      for opts <- [[], [live: true]], mode <- [:everything, [:updates, "values"], []] do
        assert {:error, %Error{type: :invalid_stream_mode}} =
                 Compiled.stream_events(triage_graph(), %{}, [stream_mode: mode] ++ opts)
      end
    end
  end

  describe "a run that fails" do
    test "a top-level parent command ends a live stream with its error" do
      graph =
        Graph.new(name: "TopLevelCommand")
        |> Graph.add_node(:escalate, fn _state -> %Command{graph: :parent, update: %{escalated: true}} end)
        |> Graph.add_edge(Graph.start(), :escalate)
        |> Graph.compile!()

      assert {:error, %Error{type: :parent_command}} = Compiled.invoke(graph, %{})
      assert {:error, %Error{type: :parent_command}} = Compiled.stream_events(graph, %{})

      assert {:ok, live} = Compiled.stream_events(graph, %{}, live: true)

      assert %Envelope{
               event: %Events.Error{error: %Error{type: :parent_command, details: %{update: %{escalated: true}}}}
             } =
               live |> Enum.to_list() |> List.last()
    end

    test "a routing function that raises fails the run in invoke and in streams alike" do
      raise_on_route = fn _state -> raise "no route for this ticket" end

      graphs = [
        Graph.new(name: "RaisingWhen")
        |> Graph.add_node(:classify, fn _state -> %{category: :billing} end)
        |> Graph.add_node(:billing, fn _state -> %{reply: "Refunds take 5 days."} end)
        |> Graph.add_edge(Graph.start(), :classify)
        |> Graph.add_edge(:classify, :billing, when: raise_on_route),
        Graph.new(name: "RaisingRouter")
        |> Graph.add_node(:classify, fn _state -> %{category: :billing} end)
        |> Graph.add_node(:billing, fn _state -> %{reply: "Refunds take 5 days."} end)
        |> Graph.add_edge(Graph.start(), :classify)
        |> BeamWeaver.Graph.StateGraph.put_branch_routes(:classify, raise_on_route, %{billing: :billing})
      ]

      for graph <- Enum.map(graphs, &Graph.compile!/1) do
        assert {:error, %Error{type: :edge_exception, message: "no route for this ticket"} = error} =
                 Compiled.invoke(graph, %{})

        assert error.details == %{node: "classify", exception: "RuntimeError"}
        assert {:error, ^error} = Compiled.stream_events(graph, %{})

        assert {:ok, live} = Compiled.stream_events(graph, %{}, live: true)
        assert %Envelope{event: %Events.Error{error: ^error}} = live |> Enum.to_list() |> List.last()
      end
    end
  end

  defp triage_graph do
    billing =
      Graph.new(name: "Billing")
      |> Graph.add_node(:reply, fn _state, runtime ->
        runtime.stream_writer.(%{stage: :replying})
        %{reply: "Refunds take 5 days."}
      end)
      |> Graph.add_edge(Graph.start(), :reply)
      |> Graph.add_edge(:reply, Graph.end_node())
      |> Graph.compile!()

    Graph.new(name: "Triage")
    |> Graph.add_node(:classify, fn _state, runtime ->
      runtime.stream_writer.(%{stage: :classifying})
      %{category: :billing}
    end)
    |> Graph.add_node(:billing, billing)
    |> Graph.add_edge(Graph.start(), :classify)
    |> Graph.add_edge(:classify, :billing)
    |> Graph.add_edge(:billing, Graph.end_node())
    |> Graph.compile!()
  end

  # What a test can compare between two runs: everything but ids and times.
  defp signatures(events), do: Enum.map(events, &{label(&1), &1.node, &1.namespace, &1.step})

  defp label(%Envelope{event: event}) do
    name = event.__struct__ |> Module.split() |> List.last()

    case event do
      %Events.Task{kind: kind, node: node} -> "#{name} #{kind} #{node}"
      %Events.Debug{payload: %{type: type}} -> "#{name} #{type}"
      %Events.Message{message: message} -> "#{name} #{message.role}"
      %Events.Token{text: text} -> "#{name} #{text}"
      _event -> name
    end
  end
end
