defmodule BeamWeaver.Agent.InvalidToolCallTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models

  # A reply can carry a tool call whose arguments came back malformed or
  # truncated. No tool runs it, so before the next model call it gets an
  # error tool message right after its assistant message: the model learns
  # the call failed, and the provider sees every call answered.
  test "an invalid tool call is answered before the next model call" do
    invalid = %InvalidToolCall{id: "call_bad", name: "lookup_order", args: ~s({"order_id": "A-2), error: "invalid JSON"}

    reply =
      Message.assistant("",
        tool_calls: [%{id: "call_ok", name: "lookup_order", args: %{"order_id" => "A-1"}}],
        metadata: %{invalid_tool_calls: [invalid]}
      )

    model =
      Models.init_chat_model!("fake:chat",
        parent: self(),
        responses: [reply, "A-1 shipped; I couldn't read the second order id."]
      )

    {:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [lookup_tool()])
    assert {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where are A-1 and A-2?"]})

    answer =
      "Tool call lookup_order with id call_bad could not be executed - arguments were malformed or truncated."

    assert [
             %Message{role: :user},
             %Message{role: :assistant},
             %Message{role: :tool, tool_call_id: "call_bad", content: ^answer, metadata: %{status: "error"}},
             %Message{role: :tool, content: "shipped"},
             %Message{role: :assistant, content: "A-1 shipped; I couldn't read the second order id."}
           ] = result.messages

    # The second model call got the answer too.
    assert_received {:fake_chat_model_call, _first_call, _opts}
    assert_received {:fake_chat_model_call, second_call, _opts}
    assert Enum.any?(second_call, &match?(%Message{role: :tool, tool_call_id: "call_bad"}, &1))
  end

  defp lookup_tool do
    Tool.from_function!(
      name: "lookup_order",
      description: "Look up an order",
      input_schema: %{"type" => "object", "properties" => %{"order_id" => %{"type" => "string"}}},
      handler: fn _args, _opts -> {:ok, "shipped"} end
    )
  end
end
