defmodule BeamWeaver.Models.FakeChatModelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule OrderAgent do
    use BeamWeaver.Agent

    model("fake:chat",
      responses: [
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
        "Order A-1001 shipped on Monday."
      ]
    )

    tools(__MODULE__.tools())

    def tools do
      [
        Tool.from_function!(
          name: "lookup_order",
          description: "Look up an order",
          input_schema: %{"type" => "object", "properties" => %{"order_id" => %{"type" => "string"}}},
          handler: fn %{"order_id" => id}, _opts -> "#{id}: shipped Monday" end
        )
      ]
    end
  end

  defmodule StreamingAgent do
    use BeamWeaver.Agent

    model("fake:chat", responses: ["Hello there, Ada."], stream: true)
  end

  test "an agent plays the script turn by turn through its tool loop" do
    assert {:ok, %{messages: messages}} = OrderAgent.invoke(%{messages: [Message.user("Where is A-1001?")]})

    assert [
             %Message{role: :user},
             %Message{role: :assistant, tool_calls: [%ToolCall{name: "lookup_order", id: "call_0_0"}]} = call,
             %Message{role: :tool, content: "A-1001: shipped Monday"},
             %Message{role: :assistant, content: "Order A-1001 shipped on Monday."} = answer
           ] = messages

    assert call.metadata.fake_turn == 0
    assert answer.metadata.fake_turn == 1
  end

  test "later turns on a thread continue after the stamped replies and repeat the last entry" do
    saver = Checkpoint.ETS.new()
    opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "fake-turns"}}]

    assert {:ok, _state} = OrderAgent.invoke(%{messages: [Message.user("Where is A-1001?")]}, opts)
    assert {:ok, %{messages: messages}} = OrderAgent.invoke(%{messages: [Message.user("Thanks!")]}, opts)

    assert %Message{role: :assistant, content: "Order A-1001 shipped on Monday."} = List.last(messages)
    assert List.last(messages).metadata.fake_turn == 2
  end

  test "an unstamped history counts its assistant messages" do
    {:ok, model} = Models.init_chat_model("fake:chat", responses: ["first", "second", "third"])
    history = [Message.user("hi"), Message.assistant("earlier reply"), Message.user("again")]

    assert {:ok, %Message{content: "second"}} = ChatModel.invoke(model, history)
  end

  test "tool_calls/1 scripts parallel calls with deterministic ids" do
    {:ok, model} =
      Models.init_chat_model("fake:chat",
        responses: [FakeChatModel.tool_calls([{"lookup_order", %{"order_id" => "A-1"}}, {:refund, %{amount: 5}}])]
      )

    assert {:ok, %Message{tool_calls: [first, second]}} = ChatModel.invoke(model, [Message.user("go")])
    assert %ToolCall{id: "call_0_0", name: "lookup_order", args: %{"order_id" => "A-1"}} = first
    assert %ToolCall{id: "call_0_1", name: "refund", args: %{"amount" => 5}} = second
  end

  test "final/1 answers a response schema with JSON and a structured-output tool with a call" do
    model = %FakeChatModel{responses: [FakeChatModel.final(%{category: "billing", urgent: true})]}

    assert {:ok, %Message{content: json, metadata: %{parsed: parsed}}} =
             FakeChatModel.invoke(model, [Message.user("triage")], response_format: %{name: "Triage"})

    assert BeamWeaver.JSON.decode!(json) == %{"category" => "billing", "urgent" => true}
    assert parsed == %{"category" => "billing", "urgent" => true}

    assert {:ok, %Message{tool_calls: [%ToolCall{name: "Triage", args: %{"category" => "billing"}}]}} =
             FakeChatModel.invoke(model, [Message.user("triage")], structured_output_tool_names: ["Triage"])
  end

  test "typed streams arrive word by word, then the whole message" do
    model = %FakeChatModel{responses: ["Hello there"]}

    assert {:ok, events} = FakeChatModel.stream_typed_events(model, [Message.user("hi")], [])

    assert [
             %Envelope{event: %Events.Token{text: "Hello "}},
             %Envelope{event: %Events.MessageChunk{}},
             %Envelope{event: %Events.Token{text: "there"}},
             %Envelope{event: %Events.MessageChunk{}},
             %Envelope{event: %Events.Message{message: %Message{content: "Hello there"}}},
             %Envelope{event: %Events.Done{}}
           ] = Enum.to_list(events)
  end

  test "custom stream chunks keep the generic typed stream" do
    model = %FakeChatModel{stream_chunks: [Message.assistant("chunk")]}

    assert {:ok, events} = FakeChatModel.stream_typed_events(model, [Message.user("hi")], [])
    assert %Envelope{event: %Events.Done{}} = events |> Enum.to_list() |> List.last()
  end

  test "agents with stream: true emit the fake reply as tokens" do
    assert {:ok, events} = StreamingAgent.stream_events(%{messages: [Message.user("hi")]}, live: true)

    tokens = for %Envelope{event: %Events.Token{text: text}} <- Enum.to_list(events), do: text
    assert Enum.join(tokens) == "Hello there, Ada."
  end
end
