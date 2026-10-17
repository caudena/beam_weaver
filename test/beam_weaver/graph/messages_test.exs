defmodule BeamWeaver.Graph.MessagesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Messages
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  test "add_messages/2 and delta_reducer/2 honor the last of several remove_all markers" do
    update = [
      Message.user("X", id: "1"),
      Messages.remove_all(),
      Message.user("Y", id: "2"),
      Messages.remove_all(),
      Message.user("Z", id: "3")
    ]

    assert Messages.add_messages([], update) == [Message.user("Z", id: "3")]
    assert Messages.delta_reducer([], [update]) == [Message.user("Z", id: "3")]
  end

  describe "delta_channel/1" do
    test "gives a written message one id, which every read keeps" do
      writes = [
        Message.user("hello"),
        "hello",
        [{"user", "hello"}],
        [%{"role" => "user", "content" => "hello"}],
        Overwrite.new(["hello"])
      ]

      for write <- writes do
        graph = graph(fn _state -> %{messages: write} end)
        config = thread("ids")

        assert {:ok, %{messages: [%Message{id: id, content: "hello"}]}} =
                 Compiled.invoke(graph, %{messages: []}, config: config)

        assert is_binary(id)

        for _read <- 1..2 do
          assert {:ok, %{values: %{messages: [%Message{id: ^id}]}}} = Compiled.get_state(graph, config)
        end
      end
    end

    test "removes a message by the id the run gave it" do
      graph = graph(fn _state -> %{messages: Message.assistant("Your refund is on its way.")} end)
      config = thread("remove")

      assert {:ok, %{messages: [question, answer]}} =
               Compiled.invoke(graph, %{messages: "Where is my refund?"}, config: config)

      assert {:ok, _config} = Compiled.update_state(graph, config, %{messages: [Messages.remove(question.id)]})
      assert {:ok, %{values: %{messages: [^answer]}}} = Compiled.get_state(graph, config)
    end

    test "streams a node's messages with the ids they are saved with" do
      graph = graph(fn _state -> %{messages: [{"assistant", "On its way."}]} end)
      config = thread("stream")

      assert {:ok, events} = Compiled.stream_events(graph, %{}, config: config, stream_mode: :updates)

      assert [%Envelope{event: %Events.GraphUpdate{update: %{"agent" => %{messages: [%Message{id: id}]}}}}] =
               events

      assert {:ok, %{values: %{messages: [%Message{id: ^id}]}}} = Compiled.get_state(graph, config)
    end

    test "streams the messages of every node that writes them in the step" do
      graph =
        Graph.new(state_schema: %{messages: Messages.delta_channel()})
        |> Graph.add_node(:lookup, fn _state -> %{messages: [{"assistant", "Order A-1001 shipped."}]} end)
        |> Graph.add_node(:notify, fn _state -> %{messages: [{"assistant", "We emailed you."}]} end)
        |> Graph.add_edge(Graph.start(), :lookup)
        |> Graph.add_edge(Graph.start(), :notify)
        |> Graph.compile!()

      assert {:ok, events} = Compiled.stream_events(graph, %{}, stream_mode: :messages)
      streamed = for %Envelope{event: %Events.Message{message: message}} <- events, do: message.content
      assert Enum.sort(streamed) == ["Order A-1001 shipped.", "We emailed you."]
    end

    test "rejects a write that holds no messages, as channel/1 does" do
      for schema <- [Messages.state_schema(), %{messages: Messages.delta_channel()}] do
        graph =
          Graph.new(state_schema: schema)
          |> Graph.add_node(:agent, fn _state -> %{messages: {"robot", "Hi."}} end)
          |> Graph.add_edge(Graph.start(), :agent)
          |> Graph.compile!()

        assert {:error, %BeamWeaver.Core.Error{type: :invalid_update}} = Compiled.invoke(graph, %{messages: []})
      end
    end

    test "keeps the ids of the messages a paused step's finished nodes wrote" do
      graph =
        Graph.new(state_schema: %{messages: Messages.delta_channel()})
        |> Graph.add_node(:lookup, fn _state -> %{messages: {"assistant", "Order A-1001 shipped."}} end)
        |> Graph.add_node(:confirm, fn _state -> %{messages: {"user", Graph.interrupt("Refund it?")}} end)
        |> Graph.add_edge(Graph.start(), :lookup)
        |> Graph.add_edge(Graph.start(), :confirm)
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("paused")

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)
      assert {:ok, %{values: %{messages: [%Message{id: id}]}}} = Compiled.get_state(graph, config)
      assert {:ok, %{values: %{messages: [%Message{id: ^id}]}}} = Compiled.get_state(graph, config)

      assert {:ok, %{messages: [%Message{id: ^id}, %Message{content: "yes"}]}} =
               Compiled.resume(graph, "yes", config: config)
    end
  end

  test "channel/1 keeps an overwrite's values as they are written" do
    graph =
      Graph.new(state_schema: Messages.state_schema())
      |> Graph.add_node(:agent, fn _state -> %{messages: Overwrite.new(["hello"])} end)
      |> Graph.add_edge(Graph.start(), :agent)
      |> Graph.compile!()

    assert {:ok, %{messages: ["hello"]}} = Compiled.invoke(graph, %{messages: "hi"})
  end

  defp graph(agent) do
    Graph.new(state_schema: %{messages: Messages.delta_channel()})
    |> Graph.add_node(:agent, agent)
    |> Graph.add_edge(Graph.start(), :agent)
    |> Graph.add_edge(:agent, Graph.end_node())
    |> Graph.compile!(checkpointer: CheckpointETS.new())
  end

  defp thread(name), do: %{"configurable" => %{"thread_id" => "#{name}-#{System.unique_integer([:positive])}"}}
end
