defmodule BeamWeaver.Anthropic.StreamingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.Streaming
  alias BeamWeaver.Stream.Events

  test "parses text deltas and reconstructs final message responses" do
    body = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001","content":[],"usage":{"input_tokens":4}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hel"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}
    """

    assert Streaming.text_deltas(body) == ["hel", "lo"]

    assert Streaming.response(body) == %{
             "id" => "msg_1",
             "type" => "message",
             "role" => "assistant",
             "model" => "claude-haiku-4-5-20251001",
             "content" => [%{"type" => "text", "text" => "hello"}],
             "usage" => %{"input_tokens" => 4, "output_tokens" => 2},
             "stop_reason" => "end_turn"
           }
  end

  test "emits typed events for text and tool input JSON deltas" do
    body = """
    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"lookup","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"q\\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"beam\\"}"}}
    """

    events = Streaming.typed_events(body)

    assert Enum.any?(
             events,
             &match?(%BeamWeaver.Stream.Envelope{event: %Events.ToolCallChunk{}}, &1)
           )

    assert Enum.any?(
             events,
             &match?(%BeamWeaver.Stream.Envelope{event: %Events.MessageChunk{}}, &1)
           )
  end
end
