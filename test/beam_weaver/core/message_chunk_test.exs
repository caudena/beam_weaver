defmodule BeamWeaver.Core.MessageChunkTest do
  use ExUnit.Case, async: true

  # Upstream references:
  # - langchain/libs/core/tests/unit_tests/messages/test_ai.py
  # - langchain/libs/core/tests/unit_tests/messages/test_utils.py
  # - langchain/libs/core/tests/unit_tests/language_models/test_chat_model_stream.py

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.Core.Messages.ToolCallChunk
  alias BeamWeaver.OpenAI.Streaming

  test "text chunks merge into a final assistant message" do
    chunk =
      [
        Messages.ai_chunk("hel", id: "msg_1", metadata: %{provider: :fake}),
        Messages.ai_chunk("lo", metadata: %{finish_reason: "stop"})
      ]
      |> MessageChunk.merge_many()

    assert %Message{
             role: :assistant,
             id: "msg_1",
             content: "hello",
             metadata: %{provider: :fake, finish_reason: "stop"}
           } = MessageChunk.to_message(chunk)
  end

  test "tool call chunks merge arguments by id and finalize to decoded tool calls" do
    chunk =
      [
        Messages.ai_chunk("",
          tool_call_chunks: [
            Messages.tool_call_chunk(
              id: "call_weather",
              index: 0,
              name: "weather",
              args: ~s({"city":)
            )
          ]
        ),
        Messages.ai_chunk("",
          tool_call_chunks: [
            %{id: "call_weather", index: 0, args: ~s("Nicosia"})}
          ]
        )
      ]
      |> MessageChunk.merge_many()

    assert %Message{
             tool_calls: [
               %{id: "call_weather", name: "weather", args: %{"city" => "Nicosia"}}
             ]
           } = MessageChunk.to_message(chunk)
  end

  test "tool call chunks merge by index when providers stream id later" do
    chunk =
      [
        Messages.ai_chunk("",
          tool_call_chunks: [
            Messages.tool_call_chunk(index: 0, name: "search", args: ~s({"q":))
          ]
        ),
        Messages.ai_chunk("",
          tool_call_chunks: [
            Messages.tool_call_chunk(id: "call_search", index: 0, args: ~s("beam"}))
          ]
        )
      ]
      |> MessageChunk.merge_many()

    assert %Message{
             tool_calls: [
               %{id: "call_search", name: "search", args: %{"q" => "beam"}}
             ]
           } = MessageChunk.to_message(chunk)
  end

  test "invalid tool calls survive finalization metadata" do
    chunk =
      MessageChunk.merge(
        Messages.ai_chunk(""),
        %Messages.AIChunk{
          invalid_tool_calls: [
            %InvalidToolCall{id: "bad_1", name: "search", args: "{", error: "invalid json"}
          ]
        }
      )

    assert %Message{metadata: %{invalid_tool_calls: [%InvalidToolCall{id: "bad_1"}]}} =
             MessageChunk.to_message(chunk)
  end

  test "malformed streamed tool-call JSON becomes invalid tool-call metadata" do
    message =
      Messages.ai_chunk("",
        tool_call_chunks: [
          Messages.tool_call_chunk(id: "bad_json", index: 0, name: "search", args: "{bad")
        ]
      )
      |> MessageChunk.to_message()

    assert message.tool_calls == []

    assert %Message{metadata: %{invalid_tool_calls: [%InvalidToolCall{id: "bad_json"} = invalid]}} =
             message

    assert invalid.args == "{bad"
    assert invalid.error =~ "unexpected"
  end

  test "OpenAI Responses SSE is exposed as typed message chunks" do
    body = """
    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_weather","name":"weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\\\"city\\\":"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"\\\"Nicosia\\\"}"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"Checking."}
    """

    chunks = Streaming.message_chunks(body)

    assert Enum.any?(chunks, &match?(%Messages.AIChunk{content: "Checking."}, &1))

    assert Enum.any?(
             chunks,
             &match?(
               %Messages.AIChunk{tool_call_chunks: [%ToolCallChunk{id: "call_weather"}]},
               &1
             )
           )

    assert %Message{
             content: "Checking.",
             tool_calls: [
               %{id: "call_weather", name: "weather", args: %{"city" => "Nicosia"}}
             ]
           } =
             chunks
             |> MessageChunk.merge_many()
             |> MessageChunk.to_message()
  end

  test "OpenAI chat-completions SSE is exposed as typed message chunks" do
    body =
      [
        %{"choices" => [%{"delta" => %{"content" => "Hel"}}]},
        %{"choices" => [%{"delta" => %{"content" => "lo"}}]},
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_search",
                    "function" => %{"name" => "search", "arguments" => ~s({"q":)}
                  }
                ]
              }
            }
          ]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{"index" => 0, "function" => %{"arguments" => ~s("beam"})}}
                ]
              }
            }
          ]
        }
      ]
      |> Enum.map_join("\n\n", &("data: " <> BeamWeaver.JSON.encode!(&1)))

    assert %Message{
             content: "Hello",
             tool_calls: [
               %{id: "call_search", name: "search", args: %{"q" => "beam"}}
             ]
           } =
             body
             |> Streaming.message_chunks()
             |> MessageChunk.merge_many()
             |> MessageChunk.to_message()
  end

  test "OpenAI chat-completions parallel streamed tool calls reconstruct deterministically" do
    body =
      [
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 1,
                    "id" => "call_second",
                    "function" => %{"name" => "lookup", "arguments" => ~s({"id":)}
                  },
                  %{
                    "index" => 0,
                    "id" => "call_first",
                    "function" => %{"name" => "search", "arguments" => ~s({"q":)}
                  }
                ]
              }
            }
          ]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{"index" => 0, "function" => %{"arguments" => ~s("beam"})}},
                  %{"index" => 1, "function" => %{"arguments" => "42}"}}
                ]
              }
            }
          ]
        }
      ]
      |> Enum.map_join("\n\n", &("data: " <> BeamWeaver.JSON.encode!(&1)))

    assert %Message{
             tool_calls: [
               %{id: "call_first", name: "search", args: %{"q" => "beam"}},
               %{id: "call_second", name: "lookup", args: %{"id" => 42}}
             ]
           } =
             body
             |> Streaming.message_chunks()
             |> MessageChunk.merge_many()
             |> MessageChunk.to_message()
  end

  test "parallel streamed tool calls with same provider index stay distinct by id" do
    chunk =
      [
        Messages.ai_chunk("",
          tool_call_chunks: [
            Messages.tool_call_chunk(
              id: "tooluse_read",
              index: 0,
              name: "read_file",
              args: ~s({"path":"foo.txt"})
            )
          ]
        ),
        Messages.ai_chunk("",
          tool_call_chunks: [
            Messages.tool_call_chunk(
              id: "tooluse_search",
              index: 0,
              name: "search_text",
              args: ~s({"query":"bar"})
            )
          ]
        )
      ]
      |> MessageChunk.merge_many()

    assert [
             %{id: "tooluse_read", name: "read_file", args: %{"path" => "foo.txt"}},
             %{id: "tooluse_search", name: "search_text", args: %{"query" => "bar"}}
           ] = MessageChunk.to_message(chunk).tool_calls

    continued =
      [
        Messages.ai_chunk("",
          tool_call_chunks: [
            Messages.tool_call_chunk(id: "tooluse_read", index: 0, name: "read_file", args: "")
          ]
        ),
        Messages.ai_chunk("",
          tool_call_chunks: [
            Messages.tool_call_chunk(index: 0, args: ~s({"path":"foo.txt"}))
          ]
        )
      ]
      |> MessageChunk.merge_many()

    assert [%{id: "tooluse_read", name: "read_file", args: %{"path" => "foo.txt"}}] =
             MessageChunk.to_message(continued).tool_calls
  end

  test "indexed content block deltas merge text without creating sparse placeholders" do
    message =
      [
        Messages.ai_chunk([%{index: 0, type: :text_block, text: "I am"}]),
        Messages.ai_chunk([%{index: 0, type: :text_block_delta, text: " here"}]),
        Messages.ai_chunk([%{index: 2, type: :text_block, text: "later"}]),
        Messages.ai_chunk("")
      ]
      |> MessageChunk.merge_many()
      |> MessageChunk.to_message()

    assert [
             %{index: 0, type: :text_block, text: "I am here"},
             %{index: 2, type: :text_block, text: "later"}
           ] = message.content
  end

  test "tool call opener may stream nil args before later JSON chunks" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/language_models/test_chat_model_v3_stream.py
    # - provider streams that open a tool block without args must still assemble.
    assert %Message{
             tool_calls: [
               %{id: "call_1", name: "search", args: %{"q" => "weather"}}
             ]
           } =
             [
               Messages.ai_chunk("",
                 tool_call_chunks: [
                   Messages.tool_call_chunk(id: "call_1", index: 0, name: "search", args: nil)
                 ]
               ),
               Messages.ai_chunk("",
                 tool_call_chunks: [
                   Messages.tool_call_chunk(index: 0, args: ~s({"q":"weather"}))
                 ]
               )
             ]
             |> MessageChunk.merge_many()
             |> MessageChunk.to_message()
  end

  test "finished invalid tool call wins over stale malformed chunks" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/language_models/test_chat_model_stream.py
    # - invalid_tool_call finish should not be revived as a valid stale chunk.
    message =
      [
        Messages.ai_chunk("",
          tool_call_chunks: [
            Messages.tool_call_chunk(id: "call_1", index: 0, name: "search", args: ~s({"q":))
          ]
        ),
        %Messages.AIChunk{
          invalid_tool_calls: [
            %InvalidToolCall{
              id: "call_1",
              name: "search",
              args: ~s({"q":),
              error: "Failed to parse tool call arguments as JSON"
            }
          ]
        }
      ]
      |> MessageChunk.merge_many()
      |> MessageChunk.to_message()

    assert message.tool_calls == []
    assert [%InvalidToolCall{id: "call_1", name: "search"}] = message.metadata.invalid_tool_calls
  end

  test "message chunks keep protocol content block shapes in final output" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/language_models/test_chat_model_stream.py
    # - output content uses protocol tool_call/server-tool/image shapes, not legacy tool_use.
    message =
      [
        Messages.ai_chunk([%{type: :text, text: "Let me search."}]),
        Messages.ai_chunk([
          %{
            type: :tool_call,
            id: "call_1",
            name: "search",
            args: %{"q" => "weather"}
          },
          %{
            type: :server_tool_call,
            id: "srv_1",
            name: "web_search",
            args: %{"q" => "weather"}
          },
          %{
            type: :server_tool_result,
            tool_call_id: "srv_1",
            status: "success",
            output: "62F, clear"
          },
          %{type: :image, url: "https://example.com/cat.png", mime_type: "image/png"}
        ])
      ]
      |> MessageChunk.merge_many()
      |> MessageChunk.to_message()

    assert [
             %{type: :text, text: "Let me search."},
             %{type: :tool_call, id: "call_1", args: %{"q" => "weather"}},
             %{type: :server_tool_call, id: "srv_1", args: %{"q" => "weather"}},
             %{type: :server_tool_result, tool_call_id: "srv_1"},
             %{type: :image, url: "https://example.com/cat.png", mime_type: "image/png"}
           ] = message.content

    refute Enum.any?(message.content, &match?(%{"type" => "tool_use"}, &1))
  end

  test "content block structs preserve provider-specific unknown blocks" do
    assert %ContentBlock.Text{text: "hello", metadata: %{index: 0}} =
             ContentBlock.text("hello", %{index: 0})

    assert %ContentBlock.Reasoning{reasoning: "because"} =
             ContentBlock.reasoning("because")

    assert %ContentBlock.Unknown{
             provider_type: "vendor.special",
             value: %{"raw" => true},
             metadata: %{provider: :vendor}
           } =
             ContentBlock.unknown("vendor.special", %{"raw" => true}, %{provider: :vendor})
  end
end
