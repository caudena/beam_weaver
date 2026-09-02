defmodule BeamWeaver.Anthropic.StreamingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Anthropic.Streaming
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.Stream.Envelope
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

  test "typed tool fragments retain their block kind across transport batches" do
    start = %{
      "data" => %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "lookup",
          "input" => %{}
        }
      }
    }

    delta = %{
      "data" => %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"q":"beam"})}
      }
    }

    {start_events, state} = Streaming.typed_events([start], nil)
    {delta_events, _state} = Streaming.typed_events([delta], state)

    message =
      (start_events ++ delta_events)
      |> Enum.flat_map(fn
        %Envelope{event: %Events.MessageChunk{chunk: chunk}} -> [chunk]
        _event -> []
      end)
      |> MessageChunk.merge_many()
      |> MessageChunk.to_message()

    assert [%{id: "toolu_1", name: "lookup", args: %{"q" => "beam"}}] = message.tool_calls
    refute Enum.any?(message.content, &match?(%{type: :server_tool_call_chunk}, &1))
  end

  test "typed thinking events reconstruct one signed block for replay" do
    transport_batches = [
      %{
        "data" => %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
        }
      },
      %{
        "data" => %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "Need "}
        }
      },
      %{
        "data" => %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "tools"}
        }
      },
      %{
        "data" => %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "signature_delta", "signature" => "signed-thinking"}
        }
      },
      %{"data" => %{"type" => "content_block_stop", "index" => 0}}
    ]

    message =
      transport_batches
      |> Enum.flat_map(&Streaming.typed_events([&1]))
      |> Enum.flat_map(fn
        %Envelope{event: %Events.MessageChunk{chunk: chunk}} -> [chunk]
        _event -> []
      end)
      |> MessageChunk.merge_many()
      |> MessageChunk.to_message()

    assert {:ok, {nil, [%{"role" => "assistant", "content" => content}]}} =
             Messages.format_messages([message])

    assert Enum.filter(content, &(&1["type"] == "thinking")) == [
             %{
               "type" => "thinking",
               "thinking" => "Need tools",
               "signature" => "signed-thinking"
             }
           ]
  end

  test "typed redacted thinking replays the exact provider block" do
    transport_batches = [
      %{
        "data" => %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "redacted_thinking", "data" => "opaque"}
        }
      },
      %{"data" => %{"type" => "content_block_stop", "index" => 0}}
    ]

    message =
      transport_batches
      |> Enum.flat_map(&Streaming.typed_events([&1]))
      |> Enum.flat_map(fn
        %Envelope{event: %Events.MessageChunk{chunk: chunk}} -> [chunk]
        _event -> []
      end)
      |> MessageChunk.merge_many()
      |> MessageChunk.to_message()

    assert {:ok, {nil, [%{"role" => "assistant", "content" => content}]}} =
             Messages.format_messages([message])

    assert content == [%{"type" => "redacted_thinking", "data" => "opaque"}]
  end

  test "message_delta carries usage metadata as a map and preserves response metadata" do
    body = """
    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":5,"output_tokens":2}}
    """

    chunk =
      Streaming.typed_events(body)
      |> Enum.find_value(fn
        %BeamWeaver.Stream.Envelope{event: %Events.MessageChunk{chunk: chunk}} -> chunk
        _other -> nil
      end)

    assert chunk
    # response metadata is retained (not overwritten by usage)...
    assert chunk.metadata.stop_reason == "end_turn"
    # ...and usage_metadata is a plain usage map, not a Message struct.
    assert %{input_tokens: 5, output_tokens: 2, total_tokens: 7} = chunk.metadata.usage_metadata
  end
end
