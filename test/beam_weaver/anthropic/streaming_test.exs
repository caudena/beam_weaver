defmodule BeamWeaver.Anthropic.StreamingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Anthropic.Streaming
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.Provider.SSE
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

    assert body |> SSE.events() |> Streaming.text_deltas() == ["hel", "lo"]

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

  test "streamed on-demand compaction retains the complete signed block" do
    block = %{
      "type" => "compaction",
      "content" => "Summary of decisions",
      "signature" => "signed-summary"
    }

    events = [
      %{
        "data" => %{
          "type" => "message_start",
          "message" => %{
            "id" => "msg_compact",
            "model" => "claude-opus-5-5",
            "role" => "assistant",
            "content" => [],
            "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
          }
        }
      },
      %{"data" => %{"type" => "content_block_start", "index" => 0, "content_block" => block}},
      %{"data" => %{"type" => "content_block_stop", "index" => 0}},
      %{
        "data" => %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "compaction"},
          "usage" => %{
            "iterations" => [%{"type" => "compaction", "input_tokens" => 100, "output_tokens" => 50}]
          }
        }
      }
    ]

    response = Streaming.response(events)
    assert response["content"] == [block]
    assert response["stop_reason"] == "compaction"

    assert {:ok, message} = Messages.response_to_message(response)
    assert message.usage_metadata.input_tokens == 100
    assert message.usage_metadata.output_tokens == 50
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

    {events, _state} = body |> SSE.events() |> Streaming.typed_events(nil)

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

    message = merged_message(start_events ++ delta_events)

    assert [%{id: "toolu_1", name: "lookup", args: %{"q" => "beam"}}] = message.tool_calls
    refute Enum.any?(message.content, &match?(%{type: :server_tool_call_chunk}, &1))
  end

  test "a streamed tool call replays as a tool_use block, without its input deltas" do
    batches = [
      %{
        "data" => %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}}
      },
      %{
        "data" => %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "Checking."}
        }
      },
      %{
        "data" => %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup", "input" => %{}}
        }
      },
      %{
        "data" => %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"q":)}
        }
      },
      %{
        "data" => %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("beam"})}
        }
      }
    ]

    {events, _state} = Streaming.typed_events(batches, nil)

    streamed = merged_message(events)

    assert {:ok, {_system, [_user, %{"role" => "assistant", "content" => content}, _tool]}} =
             BeamWeaver.Anthropic.Messages.format_messages([
               BeamWeaver.Core.Message.user("lookup beam"),
               streamed,
               BeamWeaver.Core.Message.tool("Beam is an Elixir VM", tool_call_id: "toolu_1")
             ])

    refute Enum.any?(content, &(&1["type"] == "input_json_delta"))
    assert %{"type" => "tool_use", "id" => "toolu_1", "input" => %{"q" => "beam"}} = List.last(content)
  end

  test "a streamed server tool call replays as the blocks Anthropic sent" do
    search_use = %{"type" => "server_tool_use", "id" => "srvtoolu_1", "name" => "web_search", "input" => %{}}

    search_result = %{
      "type" => "web_search_tool_result",
      "tool_use_id" => "srvtoolu_1",
      "content" => [
        %{"type" => "web_search_result", "url" => "https://x.test", "title" => "X", "encrypted_content" => "abc"}
      ]
    }

    events =
      [
        %{"type" => "content_block_start", "index" => 0, "content_block" => search_use},
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"query":)}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("beam"})}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "content_block_start", "index" => 1, "content_block" => search_result},
        %{"type" => "content_block_stop", "index" => 1},
        %{"type" => "content_block_start", "index" => 2, "content_block" => %{"type" => "text", "text" => ""}},
        %{
          "type" => "content_block_delta",
          "index" => 2,
          "delta" => %{"type" => "text_delta", "text" => "BEAM is a VM."}
        },
        %{"type" => "content_block_stop", "index" => 2}
      ]
      |> Enum.map(&%{"data" => &1})

    expected = [
      %{search_use | "input" => %{"query" => "beam"}},
      search_result,
      %{"type" => "text", "text" => "BEAM is a VM."}
    ]

    replayed = fn reply ->
      assert {:ok, {nil, [_user, %{"role" => "assistant", "content" => content}, _next]}} =
               Messages.format_messages([
                 BeamWeaver.Core.Message.user("What is BEAM?"),
                 reply,
                 BeamWeaver.Core.Message.user("Thanks")
               ])

      content
    end

    # Typed events, merged as an agent with `stream: true` does, and the
    # same reply after it is saved and loaded.
    {typed, _state} = Streaming.typed_events(events, nil)

    merged = merged_message(typed)

    assert replayed.(merged) == expected
    assert {:ok, saved} = BeamWeaver.Serialization.dump(merged)
    assert {:ok, loaded} = BeamWeaver.Serialization.load(saved)
    assert replayed.(loaded) == expected

    # The collected response.
    assert {:ok, collected} = events |> Streaming.response() |> Messages.response_to_message()
    assert [%{type: :server_tool_call, args: %{"query" => "beam"}} | _rest] = collected.content
    assert replayed.(collected) == expected
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

    {events, _state} = Streaming.typed_events(transport_batches, nil)

    message = merged_message(events)

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

    {events, _state} = Streaming.typed_events(transport_batches, nil)

    message = merged_message(events)

    assert {:ok, {nil, [%{"role" => "assistant", "content" => content}]}} =
             Messages.format_messages([message])

    assert content == [%{"type" => "redacted_thinking", "data" => "opaque"}]
  end

  test "message_delta carries usage metadata as a map and preserves response metadata" do
    body = """
    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":5,"output_tokens":2}}
    """

    {events, _state} = body |> SSE.events() |> Streaming.typed_events(nil)

    chunk =
      Enum.find_value(events, fn
        %BeamWeaver.Stream.Envelope{event: %Events.MessageChunk{chunk: chunk}} -> chunk
        _other -> nil
      end)

    assert chunk
    # response metadata is retained (not overwritten by usage)...
    assert chunk.metadata.stop_reason == "end_turn"
    # ...and usage_metadata is a plain usage map, not a Message struct.
    assert %{input_tokens: 5, output_tokens: 2, total_tokens: 7} = chunk.metadata.usage_metadata
  end

  test "preserves Anthropic diagnostics and final input-transformation overrides" do
    events = [
      %{
        "data" => %{
          "type" => "message_start",
          "message" => %{
            "id" => "msg_transform",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-fable-5-1",
            "content" => [],
            "usage" => %{"input_tokens" => 3},
            "diagnostics" => %{"cache_miss_reason" => %{"type" => "messages_changed"}},
            "input_transformations" => []
          }
        }
      },
      %{
        "data" => %{
          "type" => "message_delta",
          "delta" => %{
            "stop_reason" => "refusal",
            "stop_details" => %{
              "type" => "refusal",
              "fallback_credit_token" => "credit-token"
            }
          },
          "input_transformations" => [
            %{
              "type" => "thinking_dropped",
              "path" => "messages.1.content.0",
              "reason" => "model_binding_mismatch"
            },
            %{
              "type" => "thinking_mismatch_allowed",
              "path" => "messages.2.content.0",
              "reason" => "prefix_binding_mismatch"
            }
          ],
          "usage" => %{
            "output_tokens" => 2,
            "fallback_credit" => %{"status" => %{"type" => "redeemed"}},
            "iterations" => [%{"type" => "fallback_message", "output_tokens" => 2}]
          }
        }
      }
    ]

    response = Streaming.response(events)
    assert response["diagnostics"]["cache_miss_reason"]["type"] == "messages_changed"

    assert [%{"type" => "thinking_dropped"}, %{"type" => "thinking_mismatch_allowed"}] =
             response["input_transformations"]

    assert response["stop_details"]["fallback_credit_token"] == "credit-token"

    {typed, _state} = Streaming.typed_events(events, nil)

    chunks =
      Enum.flat_map(typed, fn
        %Envelope{event: %Events.MessageChunk{chunk: chunk}} -> [chunk]
        _event -> []
      end)

    [start_chunk, delta_chunk] = chunks
    assert start_chunk.metadata.diagnostics["cache_miss_reason"]["type"] == "messages_changed"
    assert delta_chunk.metadata.stop_details["fallback_credit_token"] == "credit-token"

    assert [%{"type" => "thinking_dropped"}, %{"type" => "thinking_mismatch_allowed"}] =
             delta_chunk.metadata.input_transformations

    assert delta_chunk.metadata.usage_metadata.fallback_credit["status"]["type"] == "redeemed"

    message = chunks |> MessageChunk.merge_many() |> MessageChunk.to_message()

    assert [%{"type" => "thinking_dropped"}, %{"type" => "thinking_mismatch_allowed"}] =
             message.metadata.input_transformations

    assert message.metadata.stop_details["fallback_credit_token"] == "credit-token"
  end

  defp merged_message(events) do
    events
    |> Enum.flat_map(fn
      %Envelope{event: %Events.MessageChunk{chunk: chunk}} -> [chunk]
      _event -> []
    end)
    |> MessageChunk.merge_many()
    |> MessageChunk.to_message()
  end
end
