defmodule BeamWeaver.Provider.MessageCodecTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.Utils
  alias BeamWeaver.Provider.MessageCodec

  @call Messages.tool_call(id: "call_1", name: "lookup", args: %{"q" => "x"})

  test "an OpenAI assistant message with tool calls encodes to one Responses input item per part" do
    message = Message.assistant("Checking.", tool_calls: [@call])

    assert {:ok, [%{"type" => "message", "role" => "assistant"}, %{"type" => "function_call", "call_id" => "call_1"}]} =
             MessageCodec.encode(message, provider: :openai)

    assert {:ok, %{"type" => "message", "role" => "user"}} = MessageCodec.encode(Message.user("hi"), provider: :openai)
    assert {:ok, %{"role" => "assistant"}} = MessageCodec.encode(message, provider: :anthropic)
  end

  test "to_openai_messages with api: :responses returns a flat list of input items" do
    assert {:ok, items} =
             Utils.to_openai_messages([Message.user("hi"), Message.assistant("Checking.", tool_calls: [@call])],
               api: :responses
             )

    assert [
             %{"type" => "message", "role" => "user"},
             %{"type" => "message", "role" => "assistant"},
             %{"type" => "function_call", "call_id" => "call_1"}
           ] = items
  end
end
