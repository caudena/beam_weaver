defmodule BeamWeaver.OpenAI.StreamingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.OpenAI.Streaming
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  test "parses SSE events and keeps reasoning summaries separate from text deltas" do
    body = """
    event: response.output_item.added
    data: {"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_1"}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","delta":"thinking"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"answer"}

    data: [DONE]
    """

    assert [
             %{
               "event" => "response.output_item.added",
               "data" => %{"item" => %{"type" => "reasoning"}}
             },
             %{"event" => "response.reasoning_summary_text.delta"},
             %{"event" => "response.output_text.delta"}
           ] = Streaming.events(body)

    assert Streaming.reasoning_summary_deltas(body) == ["thinking"]
    assert Streaming.text_deltas(body) == ["answer"]
  end

  test "typed events expose Responses API text, tool-call, message chunk, usage, and done events" do
    body = """
    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_weather","name":"weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\\\"city\\\":\\\"Nicosia\\\"}"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"Checking"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_1","usage":{"total_tokens":12}}}
    """

    events = Streaming.typed_events(body)

    assert Enum.all?(events, &match?(%Envelope{metadata: %{provider: :openai}}, &1))
    assert Enum.any?(events, &match?(%Envelope{event: %Events.Token{text: "Checking"}}, &1))
    assert Enum.any?(events, &match?(%Envelope{event: %Events.MessageChunk{}}, &1))

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.ToolCallChunk{
                   chunk: %Messages.ToolCallChunk{id: "call_weather", name: "weather"}
                 }
               },
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(%Envelope{event: %Events.Done{usage: %{"total_tokens" => 12}}}, &1)
           )
  end

  test "typed events preserve incomplete and failed Responses terminals" do
    incomplete_response = %{
      "id" => "resp_incomplete",
      "status" => "incomplete",
      "incomplete_details" => %{"reason" => "max_output_tokens"},
      "output" => [],
      "usage" => %{"input_tokens" => 7, "output_tokens" => 3, "total_tokens" => 10}
    }

    incomplete_body = """
    event: response.incomplete
    data: {"type":"response.incomplete","sequence_number":4,"response":#{BeamWeaver.JSON.encode!(incomplete_response)}}
    """

    assert [
             %Envelope{
               event: %Events.Done{
                 result: ^incomplete_response,
                 usage: %{"total_tokens" => 10} = usage,
                 metadata: incomplete_metadata
               }
             }
           ] = Streaming.typed_events(incomplete_body)

    assert usage["input_tokens"] == 7

    assert incomplete_metadata == %{
             event_type: "response.incomplete",
             sequence_number: 4,
             status: "incomplete",
             usage: incomplete_response["usage"]
           }

    failed_response = %{
      "id" => "resp_failed",
      "status" => "failed",
      "error" => %{"code" => "server_error", "message" => "generation failed"},
      "output" => [],
      "usage" => %{"input_tokens" => 2, "output_tokens" => 0, "total_tokens" => 2}
    }

    failed_data = %{
      "type" => "response.failed",
      "sequence_number" => 9,
      "response" => failed_response
    }

    failed_body = "event: response.failed\ndata: #{BeamWeaver.JSON.encode!(failed_data)}\n\n"

    assert [
             %Envelope{
               event: %Events.Error{
                 error: %BeamWeaver.Core.Error{
                   type: :response_failed,
                   message: "generation failed",
                   details: failed_details
                 },
                 metadata: failed_metadata
               }
             }
           ] = Streaming.typed_events(failed_body)

    assert failed_details.event == failed_data
    assert failed_details.response == failed_response
    assert failed_details.status == "failed"
    assert failed_details.usage == failed_response["usage"]

    assert failed_metadata == %{
             event_type: "response.failed",
             sequence_number: 9,
             status: "failed",
             usage: failed_response["usage"]
           }
  end

  test "typed events preserve hosted and custom output-item lifecycle without duplicating message chunks" do
    body = """
    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"id":"ws_1","type":"web_search_call","status":"in_progress"}}

    event: response.web_search_call.in_progress
    data: {"type":"response.web_search_call.in_progress","output_index":0,"item_id":"ws_1","sequence_number":1}

    event: response.web_search_call.searching
    data: {"type":"response.web_search_call.searching","output_index":0,"item_id":"ws_1","sequence_number":2}

    event: response.web_search_call.failed
    data: {"type":"response.web_search_call.failed","output_index":0,"item_id":"ws_1","sequence_number":3,"status":"failed","error":{"code":"search_failed","message":"upstream unavailable"}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"id":"ws_1","type":"web_search_call","status":"failed"}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"lookup","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","delta":"{}"}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":2,"item":{"id":"ct_1","type":"custom_tool_call","call_id":"custom_1","name":"shell","input":""}}

    event: response.custom_tool_call_input.delta
    data: {"type":"response.custom_tool_call_input.delta","output_index":2,"item_id":"ct_1","delta":"echo hi"}

    event: response.custom_tool_call_input.done
    data: {"type":"response.custom_tool_call_input.done","output_index":2,"item_id":"ct_1","input":"echo hi"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":2,"item":{"id":"ct_1","type":"custom_tool_call","call_id":"custom_1","name":"shell","input":"echo hi","status":"completed"}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":3,"item":{"id":"patch_1","type":"apply_patch_call","status":"in_progress"}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":3,"item":{"id":"patch_1","type":"apply_patch_call","status":"completed","operation":{"type":"create_file","path":"a.txt"}}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","item_id":"rs_1","delta":"thinking"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"answer"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[],"usage":{"total_tokens":4}}}
    """

    events = Streaming.typed_events(body)

    custom_payloads =
      Enum.flat_map(events, fn
        %Envelope{event: %Events.Custom{payload: payload}} -> [payload]
        _event -> []
      end)

    assert Enum.map(custom_payloads, &get_in(&1, ["data", "type"])) == [
             "response.output_item.added",
             "response.web_search_call.in_progress",
             "response.web_search_call.searching",
             "response.web_search_call.failed",
             "response.output_item.done",
             "response.output_item.added",
             "response.custom_tool_call_input.delta",
             "response.custom_tool_call_input.done",
             "response.output_item.done",
             "response.output_item.added",
             "response.output_item.done"
           ]

    assert get_in(Enum.at(custom_payloads, 3), ["data", "error", "code"]) == "search_failed"

    assert Enum.map(
             Enum.filter(custom_payloads, &(get_in(&1, ["data", "type"]) == "response.output_item.added")),
             &get_in(&1, ["data", "item", "type"])
           ) == ["web_search_call", "custom_tool_call", "apply_patch_call"]

    assert ["answer"] ==
             Enum.flat_map(events, fn
               %Envelope{event: %Events.Token{text: text}} -> [text]
               _event -> []
             end)

    assert 2 == Enum.count(events, &match?(%Envelope{event: %Events.ToolCallChunk{}}, &1))

    assert 1 ==
             Enum.count(events, fn
               %Envelope{
                 event: %Events.MessageChunk{
                   chunk: %Messages.AIChunk{content: [%ContentBlock.Reasoning{}]}
                 }
               } ->
                 true

               _event ->
                 false
             end)

    assert Enum.any?(events, &match?(%Envelope{event: %Events.Done{}}, &1))
  end

  test "typed events tolerate in-memory prompt cache retention literal drift" do
    # Upstream reference:
    body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_123","prompt_cache_retention":"in_memory","output":[]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_123","prompt_cache_retention":"in_memory","usage":{"total_tokens":5},"output":[]}}
    """

    assert Enum.any?(
             Streaming.typed_events(body),
             &match?(%Envelope{event: %Events.Done{usage: %{"total_tokens" => 5}}}, &1)
           )
  end

  test "typed events preserve Responses reasoning deltas as message chunks" do
    # Upstream reference:
    # - reasoning deltas are streamed as typed content, not dropped.
    body = """
    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","item_id":"rs_1","delta":"thinking"}
    """

    events = Streaming.typed_events(body)

    assert [
             %Envelope{
               event: %Events.MessageChunk{
                 chunk: %Messages.AIChunk{
                   id: "rs_1",
                   content: [%ContentBlock.Reasoning{reasoning: "thinking"}]
                 }
               }
             }
           ] = events
  end

  test "typed events preserve xAI reasoning_text deltas as non-text message chunks" do
    body = """
    event: response.reasoning_text.delta
    data: {"type":"response.reasoning_text.delta","item_id":"rs_1","delta":"thinking"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"answer"}
    """

    events = Streaming.typed_events(body)

    assert %Envelope{
             event: %Events.MessageChunk{
               chunk: %Messages.AIChunk{
                 id: "rs_1",
                 content: [%ContentBlock.Reasoning{reasoning: "thinking"}]
               }
             }
           } = Enum.find(events, &match?(%Envelope{event: %Events.MessageChunk{}}, &1))

    chunks =
      events
      |> Enum.flat_map(fn
        %Envelope{event: %Events.MessageChunk{chunk: chunk}} -> [chunk]
        _event -> []
      end)

    assert Message.text(MessageChunk.to_message(MessageChunk.merge_many(chunks))) == "answer"
    assert Streaming.reasoning_summary_deltas(body) == ["thinking"]
    assert Streaming.text_deltas(body) == ["answer"]
  end

  test "typed events expose chat-completions chunks and terminal finish event" do
    body =
      [
        %{"choices" => [%{"delta" => %{"content" => "Hel"}}]},
        %{"choices" => [%{"delta" => %{"content" => "lo"}}]},
        %{"choices" => [%{"finish_reason" => "stop", "delta" => %{}}]}
      ]
      |> Enum.map_join("\n\n", &("data: " <> BeamWeaver.JSON.encode!(&1)))

    events = Streaming.typed_events(body)

    assert Enum.map(
             Enum.filter(events, &match?(%Envelope{event: %Events.Token{}}, &1)),
             fn %Envelope{event: %Events.Token{text: text}} -> text end
           ) == ["Hel", "lo"]

    assert Enum.any?(events, &match?(%Envelope{event: %Events.Done{}}, &1))
  end

  test "chat-completions usage chunks emit typed done usage metadata" do
    # Upstream reference:
    # - streamed usage chunks are emitted separately from token deltas.
    body =
      [
        %{"choices" => [%{"delta" => %{"content" => "hi"}}]},
        %{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 3,
            "completion_tokens" => 2,
            "total_tokens" => 5
          }
        }
      ]
      |> Enum.map_join("\n\n", &("data: " <> BeamWeaver.JSON.encode!(&1)))

    events = Streaming.typed_events(body)

    assert Enum.any?(events, &match?(%Envelope{event: %Events.Token{text: "hi"}}, &1))

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.Done{
                   usage: %{
                     "prompt_tokens" => 3,
                     "completion_tokens" => 2,
                     "total_tokens" => 5
                   }
                 }
               },
               &1
             )
           )
  end

  test "Responses usage-only completion preserves nested and unknown usage metadata" do
    # Upstream reference:
    # - usage-only terminal events and provider-specific token details are preserved.
    body = """
    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_usage","usage":{"input_tokens":7,"output_tokens":3,"total_tokens":10,"input_tokens_details":{"cached_tokens":2},"output_tokens_details":{"reasoning_tokens":1},"provider_new_usage":{"kept":true}}}}
    """

    assert [
             %Envelope{
               event: %Events.Done{
                 usage: %{
                   "input_tokens" => 7,
                   "output_tokens" => 3,
                   "total_tokens" => 10,
                   "input_tokens_details" => %{"cached_tokens" => 2},
                   "output_tokens_details" => %{"reasoning_tokens" => 1},
                   "provider_new_usage" => %{"kept" => true}
                 }
               }
             }
           ] = Streaming.typed_events(body)
  end

  test "chat-completions usage-only chunks preserve unknown usage fields for tracing" do
    # Upstream reference:
    # - usage chunks can arrive without choices and should not be dropped.
    body =
      [
        %{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 5,
            "completion_tokens" => 0,
            "total_tokens" => 5,
            "prompt_tokens_details" => %{"cached_tokens" => 4},
            "vendor_token_breakdown" => %{"audio_tokens" => 1}
          }
        }
      ]
      |> Enum.map_join("\n\n", &("data: " <> BeamWeaver.JSON.encode!(&1)))

    assert [
             %Envelope{
               event: %Events.Done{
                 usage: %{
                   "prompt_tokens_details" => %{"cached_tokens" => 4},
                   "vendor_token_breakdown" => %{"audio_tokens" => 1}
                 }
               }
             }
           ] = Streaming.typed_events(body)
  end

  test "chat-completions unknown streamed delta fields are preserved on message chunks" do
    # Upstream reference:
    # - provider-specific streamed blocks are preserved instead of dropped.
    body =
      [
        %{
          "choices" => [
            %{
              "delta" => %{
                "content" => "hi",
                "reasoning" => %{"summary" => "kept"},
                "provider_new_block" => %{"value" => 1}
              }
            }
          ]
        }
      ]
      |> Enum.map_join("\n\n", &("data: " <> BeamWeaver.JSON.encode!(&1)))

    chunks = Streaming.message_chunks(body)

    assert Enum.any?(chunks, fn
             %Messages.AIChunk{metadata: %{openai_delta: delta}} ->
               delta["reasoning"] == %{"summary" => "kept"} and
                 delta["provider_new_block"] == %{"value" => 1}

             _chunk ->
               false
           end)
  end

  test "reconstructs response output items from Responses API lifecycle events" do
    body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_1","model":"gpt-5.4","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}

    event: response.reasoning_summary_part.added
    data: {"type":"response.reasoning_summary_part.added","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":0,"delta":"looked"}

    event: response.reasoning_summary_text.done
    data: {"type":"response.reasoning_summary_text.done","output_index":0,"summary_index":0,"text":"looked up weather"}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"msg_1","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":1,"content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":1,"content_index":0,"delta":"It "}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":1,"content_index":0,"delta":"is sunny."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":1,"content_index":0,"text":"It is sunny."}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"msg_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"It is sunny."}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_1","model":"gpt-5.4","usage":{"total_tokens":18},"output":[]}}
    """

    assert %{
             "id" => "resp_1",
             "model" => "gpt-5.4",
             "usage" => %{"total_tokens" => 18},
             "output" => [
               %{
                 "id" => "rs_1",
                 "type" => "reasoning",
                 "summary" => [%{"type" => "summary_text", "text" => "looked up weather"}]
               },
               %{
                 "id" => "msg_1",
                 "type" => "message",
                 "content" => [%{"type" => "output_text", "text" => "It is sunny."}]
               }
             ]
           } = Streaming.response(body)

    assert Streaming.text_deltas(body) == ["It ", "is sunny."]
  end

  test "builds valid content-block lifecycle events for reasoning and text" do
    body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_1","model":"gpt-5.4","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}

    event: response.reasoning_summary_part.added
    data: {"type":"response.reasoning_summary_part.added","output_index":0,"item_id":"rs_1","summary_index":0,"part":{"type":"summary_text","text":""}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","output_index":0,"item_id":"rs_1","summary_index":0,"delta":"looked "}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","output_index":0,"item_id":"rs_1","summary_index":0,"delta":"up weather"}

    event: response.reasoning_summary_text.done
    data: {"type":"response.reasoning_summary_text.done","output_index":0,"item_id":"rs_1","summary_index":0,"text":"looked up weather"}

    event: response.reasoning_summary_part.done
    data: {"type":"response.reasoning_summary_part.done","output_index":0,"item_id":"rs_1","summary_index":0,"part":{"type":"summary_text","text":"looked up weather"}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"msg_1","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":1,"item_id":"msg_1","content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":1,"item_id":"msg_1","content_index":0,"delta":"It is sunny."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":1,"item_id":"msg_1","content_index":0,"text":"It is sunny."}

    event: response.content_part.done
    data: {"type":"response.content_part.done","output_index":1,"item_id":"msg_1","content_index":0,"part":{"type":"output_text","text":"It is sunny."}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_1","model":"gpt-5.4","usage":{"total_tokens":18},"output":[]}}
    """

    events = Streaming.lifecycle_events(body)

    assert_valid_lifecycle(events)

    assert List.first(events) == %{
             "event" => "message-start",
             "message" => %{"id" => "resp_1", "model" => "gpt-5.4"}
           }

    assert [
             %{
               "event" => "content-block-finish",
               "index" => 0,
               "content" => %{
                 "type" => "reasoning",
                 "id" => "rs_1",
                 "reasoning" => "looked up weather"
               }
             }
           ] =
             Enum.filter(
               events,
               &match?(
                 %{"event" => "content-block-finish", "content" => %{"type" => "reasoning"}},
                 &1
               )
             )

    assert [
             %{
               "event" => "content-block-delta",
               "index" => 0,
               "delta" => %{"type" => "reasoning-delta", "reasoning" => "looked "}
             },
             %{
               "event" => "content-block-delta",
               "index" => 0,
               "delta" => %{"type" => "reasoning-delta", "reasoning" => "up weather"}
             }
           ] =
             Enum.filter(
               events,
               &match?(
                 %{"event" => "content-block-delta", "delta" => %{"type" => "reasoning-delta"}},
                 &1
               )
             )

    assert %{
             "event" => "content-block-finish",
             "index" => 1,
             "content" => %{"type" => "text", "id" => "msg_1", "text" => "It is sunny."}
           } in events

    assert List.last(events) == %{
             "event" => "message-finish",
             "message" => %{
               "id" => "resp_1",
               "model" => "gpt-5.4",
               "usage" => %{"total_tokens" => 18}
             }
           }
  end

  test "reconstructs streamed function-call arguments and preserves namespace" do
    body = """
    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"search","namespace":"weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\\\"city\\\":"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"\\\"San Francisco\\\"}"}

    event: response.function_call_arguments.done
    data: {"type":"response.function_call_arguments.done","output_index":0,"item_id":"fc_1","name":"search","arguments":"{\\\"city\\\":\\\"San Francisco\\\"}"}
    """

    assert [
             %{
               "type" => "function_call",
               "id" => "fc_1",
               "call_id" => "call_1",
               "name" => "search",
               "namespace" => "weather",
               "arguments" => ~s({"city":"San Francisco"})
             }
           ] = Streaming.output_items(body)
  end

  test "builds lifecycle events for streamed function-call arguments" do
    body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_tool","model":"gpt-5.4-mini","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"search","namespace":"weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\\\"city\\\":"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"\\\"San Francisco\\\"}"}

    event: response.function_call_arguments.done
    data: {"type":"response.function_call_arguments.done","output_index":0,"item_id":"fc_1","name":"search","arguments":"{\\\"city\\\":\\\"San Francisco\\\"}"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"search","namespace":"weather","arguments":"{\\\"city\\\":\\\"San Francisco\\\"}","status":"completed"}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_tool","model":"gpt-5.4-mini","output":[]}}
    """

    events = Streaming.lifecycle_events(body)

    assert_valid_lifecycle(events)

    assert [
             %{
               "event" => "content-block-start",
               "index" => 0,
               "content" => %{
                 "type" => "tool_call_chunk",
                 "id" => "call_1",
                 "name" => "search",
                 "args" => ""
               }
             },
             %{
               "event" => "content-block-delta",
               "index" => 0,
               "delta" => %{
                 "type" => "block-delta",
                 "fields" => %{"type" => "tool_call_chunk", "args" => ~s({"city":)}
               }
             },
             %{
               "event" => "content-block-delta",
               "index" => 0,
               "delta" => %{
                 "type" => "block-delta",
                 "fields" => %{"type" => "tool_call_chunk", "args" => ~s("San Francisco"})}
               }
             },
             %{
               "event" => "content-block-finish",
               "index" => 0,
               "content" => %{
                 "type" => "tool_call",
                 "id" => "call_1",
                 "name" => "search",
                 "args" => %{"city" => "San Francisco"}
               }
             }
           ] =
             Enum.filter(
               events,
               &match?(
                 %{"event" => event}
                 when event in [
                        "content-block-start",
                        "content-block-delta",
                        "content-block-finish"
                      ],
                 &1
               )
             )
  end

  test "malformed streamed function-call arguments finish as raw args instead of crashing" do
    # Upstream reference:
    # - malformed streamed tool args become invalid/raw records at the boundary.
    body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_bad_tool","model":"gpt-5.4-mini","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_bad","call_id":"call_bad","name":"search","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_bad","delta":"{bad"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_bad","call_id":"call_bad","name":"search","arguments":"{bad","status":"completed"}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_bad_tool","model":"gpt-5.4-mini","output":[]}}
    """

    assert [
             %{
               "event" => "content-block-finish",
               "content" => %{
                 "type" => "tool_call",
                 "id" => "call_bad",
                 "name" => "search",
                 "args" => "{bad"
               }
             }
           ] =
             Streaming.lifecycle_events(body)
             |> Enum.filter(&match?(%{"event" => "content-block-finish"}, &1))

    assert [
             %{
               "type" => "function_call",
               "id" => "fc_bad",
               "call_id" => "call_bad",
               "arguments" => "{bad"
             }
           ] = Streaming.output_items(body)
  end

  test "falls back to completed response output for terminal image items" do
    body = """
    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_img","model":"gpt-4.1","output":[{"type":"image_generation_call","id":"ig_1","status":"completed","result":"base64-image","output_format":"jpeg","revised_prompt":"green word"}]}}
    """

    assert [
             %{
               "type" => "image_generation_call",
               "id" => "ig_1",
               "status" => "completed",
               "result" => "base64-image",
               "output_format" => "jpeg"
             }
           ] = Streaming.output_items(body)
  end

  test "preserves partial image frames on reconstructed image generation items" do
    body = """
    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"image_generation_call","id":"ig_1","status":"in_progress"}}

    event: response.image_generation_call.partial_image
    data: {"type":"response.image_generation_call.partial_image","output_index":0,"item_id":"ig_1","partial_image_index":0,"partial_image_b64":"first-frame"}

    event: response.image_generation_call.partial_image
    data: {"type":"response.image_generation_call.partial_image","output_index":0,"item_id":"ig_1","partial_image_index":1,"partial_image_b64":"second-frame"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"image_generation_call","id":"ig_1","status":"completed","result":"final-image","output_format":"jpeg"}}
    """

    assert Streaming.partial_images(body) == [
             %{
               "item_id" => "ig_1",
               "output_index" => 0,
               "partial_image_index" => 0,
               "partial_image_b64" => "first-frame"
             },
             %{
               "item_id" => "ig_1",
               "output_index" => 0,
               "partial_image_index" => 1,
               "partial_image_b64" => "second-frame"
             }
           ]

    assert [
             %{
               "type" => "image_generation_call",
               "id" => "ig_1",
               "status" => "completed",
               "result" => "final-image",
               "partial_images" => [
                 %{"partial_image_index" => 0, "partial_image_b64" => "first-frame"},
                 %{"partial_image_index" => 1, "partial_image_b64" => "second-frame"}
               ]
             }
           ] = Streaming.output_items(body)
  end

  test "keeps separate streamed text blocks isolated and reconciles authoritative finishes" do
    # Upstream reference:
    # - TestPerBlockAccumulation text cases.
    body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_blocks","model":"gpt-5.4","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","content":[]}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_1","content_index":0,"delta":"aaa"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_1","content_index":1,"delta":"bb"}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_1","content_index":0,"text":"XXX"}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_1","content_index":1,"text":"bb"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"XXX"},{"type":"output_text","text":"bb"}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_blocks","model":"gpt-5.4","output":[]}}
    """

    events = Streaming.lifecycle_events(body)

    assert [
             %{"event" => "content-block-finish", "content" => %{"text" => "XXX"}},
             %{"event" => "content-block-finish", "content" => %{"text" => "bb"}}
           ] =
             Enum.filter(
               events,
               &match?(%{"event" => "content-block-finish", "content" => %{"type" => "text"}}, &1)
             )

    assert [
             %{
               "type" => "message",
               "content" => [
                 %{"type" => "output_text", "text" => "XXX"},
                 %{"type" => "output_text", "text" => "bb"}
               ]
             }
           ] = Streaming.output_items(body)
  end

  test "keeps separate streamed reasoning blocks isolated" do
    # Upstream reference:
    # - TestPerBlockAccumulation reasoning cases.
    body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_reasoning","model":"gpt-5.4","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","output_index":0,"item_id":"rs_1","summary_index":0,"delta":"one"}

    event: response.reasoning_summary_text.done
    data: {"type":"response.reasoning_summary_text.done","output_index":0,"item_id":"rs_1","summary_index":0,"text":"one"}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","output_index":0,"item_id":"rs_1","summary_index":1,"delta":"two"}

    event: response.reasoning_summary_text.done
    data: {"type":"response.reasoning_summary_text.done","output_index":0,"item_id":"rs_1","summary_index":1,"text":"two"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"one"},{"type":"summary_text","text":"two"}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_reasoning","model":"gpt-5.4","output":[]}}
    """

    events = Streaming.lifecycle_events(body)

    assert [
             %{"event" => "content-block-finish", "content" => %{"reasoning" => "one"}},
             %{"event" => "content-block-finish", "content" => %{"reasoning" => "two"}}
           ] =
             Enum.filter(
               events,
               &match?(
                 %{"event" => "content-block-finish", "content" => %{"type" => "reasoning"}},
                 &1
               )
             )

    assert [
             %{
               "type" => "reasoning",
               "summary" => [
                 %{"type" => "summary_text", "text" => "one"},
                 %{"type" => "summary_text", "text" => "two"}
               ]
             }
           ] = Streaming.output_items(body)
  end

  test "preserves interleaved text function-call text lifecycle order" do
    # Upstream reference:
    # - interleaved text blocks around a tool call.
    body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_interleaved","model":"gpt-5.4","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_before","role":"assistant","content":[]}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_before","content_index":0,"delta":"before"}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_before","content_index":0,"text":"before"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_before","role":"assistant","content":[{"type":"output_text","text":"before"}]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"search","arguments":"{\\\"q\\\":\\\"x\\\"}"}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"search","arguments":"{\\\"q\\\":\\\"x\\\"}","status":"completed"}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":2,"item":{"type":"message","id":"msg_after","role":"assistant","content":[]}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":2,"item_id":"msg_after","content_index":0,"delta":"after"}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":2,"item_id":"msg_after","content_index":0,"text":"after"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":2,"item":{"type":"message","id":"msg_after","role":"assistant","content":[{"type":"output_text","text":"after"}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_interleaved","model":"gpt-5.4","output":[]}}
    """

    assert [
             %{"content" => %{"type" => "text", "text" => "before"}},
             %{"content" => %{"type" => "tool_call", "id" => "call_1", "args" => %{"q" => "x"}}},
             %{"content" => %{"type" => "text", "text" => "after"}}
           ] =
             Streaming.lifecycle_events(body)
             |> Enum.filter(&match?(%{"event" => "content-block-finish"}, &1))
  end

  defp assert_valid_lifecycle(events) do
    assert [%{"event" => "message-start"} | _] = events
    assert %{"event" => "message-finish"} = List.last(events)

    events
    |> Enum.reduce(%{next_index: 0, open: %{}, finished: MapSet.new(), accum: %{}}, fn
      %{"event" => "content-block-start", "index" => index, "content" => content}, state ->
        assert index == state.next_index
        refute Map.has_key?(state.open, index)

        %{
          state
          | next_index: index + 1,
            open: Map.put(state.open, index, content),
            accum: Map.put(state.accum, index, %{})
        }

      %{"event" => "content-block-delta", "index" => index, "delta" => delta}, state ->
        assert Map.has_key?(state.open, index)
        assert is_map(delta)
        %{state | accum: Map.update!(state.accum, index, &accumulate_delta(&1, delta))}

      %{"event" => "content-block-finish", "index" => index, "content" => content}, state ->
        assert Map.has_key?(state.open, index)
        refute MapSet.member?(state.finished, index)
        assert is_map(content)
        assert_delta_matches_finish(state.accum[index], content)

        %{
          state
          | open: Map.delete(state.open, index),
            finished: MapSet.put(state.finished, index),
            accum: Map.delete(state.accum, index)
        }

      %{"event" => "message-finish"}, state ->
        assert state.open == %{}
        state

      _event, state ->
        state
    end)
  end

  defp accumulate_delta(accum, %{"type" => "text-delta", "text" => text}) do
    Map.update(accum, "text", text, &(&1 <> text))
  end

  defp accumulate_delta(accum, %{"type" => "reasoning-delta", "reasoning" => reasoning}) do
    Map.update(accum, "reasoning", reasoning, &(&1 <> reasoning))
  end

  defp accumulate_delta(accum, %{
         "type" => "block-delta",
         "fields" => %{"type" => "tool_call_chunk", "args" => args}
       }) do
    Map.update(accum, "args", args, &(&1 <> args))
  end

  defp accumulate_delta(accum, _delta), do: accum

  defp assert_delta_matches_finish(%{"text" => text}, %{"type" => "text", "text" => text}),
    do: :ok

  defp assert_delta_matches_finish(
         %{"reasoning" => reasoning},
         %{"type" => "reasoning", "reasoning" => reasoning}
       ),
       do: :ok

  defp assert_delta_matches_finish(%{"args" => args}, %{"type" => "tool_call", "args" => parsed}) do
    assert {:ok, parsed} == BeamWeaver.JSON.decode(args)
  end

  defp assert_delta_matches_finish(_accum, _content), do: :ok
end
