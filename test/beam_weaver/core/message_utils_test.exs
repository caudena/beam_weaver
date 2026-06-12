defmodule BeamWeaver.Core.MessageUtilsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.MessageLike
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.Serialization
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Messages.Utils
  alias BeamWeaver.Provider.DecodeMessage
  alias BeamWeaver.Provider.EncodeMessage
  alias BeamWeaver.Tokenizer.StaticVocabulary

  test "message-like protocol converts binaries, tuples, maps, typed structs, and messages" do
    assert {:ok, %Message{role: :user, content: "hello"}} = MessageLike.to_message("hello")
    assert {:ok, %Message{role: :assistant, content: "hi"}} = MessageLike.to_message({"ai", "hi"})

    assert {:ok,
            %Message{
              role: :assistant,
              content: "fn",
              metadata: %{}
            }} = MessageLike.to_message({"function", "fn"})

    assert {:ok, %Message{role: :tool, tool_call_id: "call-1"}} =
             MessageLike.to_message(%{
               "role" => "tool",
               "content" => "ok",
               "tool_call_id" => "call-1"
             })

    typed =
      BeamWeaver.Core.Messages.assistant("typed",
        tool_calls: [%{id: "call-2", name: "t", args: %{}}]
      )

    assert {:ok,
            %Message{
              role: :assistant,
              content: "typed",
              tool_calls: [%{id: "call-2", name: "t", args: %{}}]
            }} =
             MessageLike.to_message(typed)

    assert {:ok,
            %Message{
              role: :assistant,
              content: "result",
              name: "lookup",
              metadata: %{}
            }} =
             Messages.function("result", name: "lookup")
             |> MessageLike.to_message()
  end

  test "safe serialization round trips metadata, usage, artifacts, and unknown content blocks" do
    message =
      Message.assistant(
        [
          ContentBlock.text("hello"),
          ContentBlock.video(%{url: "https://example.test/video.mp4"}),
          ContentBlock.unknown("provider_block", %{"raw" => true})
        ],
        id: "msg-1",
        response_metadata: %{model: "gpt"},
        usage_metadata: %{input_tokens: 1, output_tokens: 2, total_tokens: 3},
        artifacts: [%{kind: "file", id: "file-1"}],
        server_tool_calls: [%{id: "srv-1"}],
        status: :complete
      )

    encoded = Serialization.encode(message)
    assert encoded["version"] == 1
    assert encoded["usage_metadata"]["total_tokens"] == 3
    assert encoded["content"] |> length() == 3

    assert {:ok, decoded} = Serialization.decode(encoded)
    assert decoded.id == "msg-1"
    assert decoded.usage_metadata["total_tokens"] == 3
    assert decoded.response_metadata["model"] == "gpt"
    assert decoded.artifacts == [%{"kind" => "file", "id" => "file-1"}]
  end

  test "message conversion helpers round-trip message dictionaries" do
    messages = [
      {"human", "hello"},
      Message.assistant("hi", id: "a1", usage_metadata: %{total_tokens: 2})
    ]

    assert {:ok, normalized} = Utils.convert_to_messages(messages)
    assert Enum.map(normalized, & &1.role) == [:user, :assistant]

    assert {:ok, dicts} = Utils.messages_to_dict(normalized)
    assert [%{"role" => "user"}, %{"role" => "assistant", "id" => "a1"}] = dicts

    assert {:ok, restored} = Utils.messages_from_dict(dicts)
    assert Enum.map(restored, &{&1.role, Message.text(&1)}) == [user: "hello", assistant: "hi"]

    assert {:ok, %{"role" => "assistant", "content" => "hi"}} =
             Utils.message_to_dict(List.last(normalized))
  end

  test "convert_to_messages accepts serialized envelopes, developer role, tool calls, and refusal metadata" do
    messages = [
      %{
        "lc" => 1,
        "type" => "constructor",
        "id" => ["beam_weaver_core", "messages", "HumanMessage"],
        "kwargs" => %{"content" => "hello", "id" => "h1"}
      },
      %{
        "lc" => 1,
        "type" => "constructor",
        "id" => ["beam_weaver_core", "messages", "HumanMessageChunk"],
        "kwargs" => %{"content" => "streaming chunk"}
      },
      %{
        "lc" => 1,
        "type" => "constructor",
        "id" => ["beam_weaver_core", "messages", "SystemMessage"],
        "kwargs" => %{"content" => "system prompt"}
      },
      %{
        "lc" => 1,
        "type" => "constructor",
        "id" => ["beam_weaver_core", "messages", "AIMessage"],
        "kwargs" => %{
          "content" => "thinking",
          "tool_calls" => [
            %{"id" => "tc1", "name" => "search", "args" => %{"q" => "weather"}}
          ]
        }
      },
      %{"role" => "human", "content" => "via role"},
      %{"role" => "developer", "content" => "developer rules"},
      %{
        "role" => "assistant",
        "content" => "",
        "refusal" => "cannot comply",
        "tool_calls" => [
          %{
            "type" => "function",
            "id" => "call-1",
            "function" => %{"name" => "lookup", "arguments" => ~s({"q":"elixir"})}
          }
        ]
      },
      %{
        "lc" => 1,
        "type" => "constructor",
        "id" => ["beam_weaver_core", "messages", "ToolMessage"],
        "kwargs" => %{
          "content" => "result",
          "tool_call_id" => "tc1",
          "additional_kwargs" => %{"artifact" => %{"extra" => "payload"}}
        }
      },
      %{
        "lc" => 1,
        "type" => "constructor",
        "id" => ["beam_weaver_core", "messages", "FunctionMessage"],
        "kwargs" => %{"content" => "42", "name" => "get_answer"}
      }
    ]

    assert {:ok, [human, chunk, system, ai, canonical, developer, refused, tool, function]} =
             Utils.convert_to_messages(messages)

    assert %Message{role: :user, content: "hello", id: "h1"} = human
    assert %Message{role: :user, content: "streaming chunk"} = chunk
    assert %Message{role: :system, content: "system prompt"} = system
    assert [%ToolCall{id: "tc1", name: "search", args: %{"q" => "weather"}}] = ai.tool_calls
    assert %Message{role: :user, content: "via role"} = canonical
    assert developer.role == :system
    assert developer.metadata.openai_role == :developer
    assert refused.metadata.refusal == "cannot comply"

    assert [%ToolCall{id: "call-1", name: "lookup", args: %{"q" => "elixir"}}] =
             refused.tool_calls

    assert tool.role == :tool
    assert tool.tool_call_id == "tc1"
    assert tool.artifacts == [%{"extra" => "payload"}]
    assert function.role == :assistant
    assert function.name == "get_answer"
    assert function.metadata == %{}

    assert {:error, error} =
             Utils.convert_to_messages([
               %{"lc" => 1, "type" => "constructor", "id" => ["x", "Mystery"], "kwargs" => %{}}
             ])

    assert error.type in [:invalid_message, :invalid_role]

    assert {:error, missing_content} =
             Utils.convert_to_messages([%{"role" => "assistant", "refusal" => "cannot comply"}])

    assert missing_content.type == :invalid_message

    assert {:error, partial_envelope} =
             Utils.convert_to_messages([%{"lc" => 1, "content" => "missing other fields"}])

    assert partial_envelope.type in [:invalid_message, :invalid_role]
  end

  test "OpenAI conversion helper returns chat messages by default and Responses input on request" do
    assert {:ok, []} = Utils.convert_to_openai_messages([])

    assert {:ok, %{"role" => "user", "content" => "hello"}} =
             Utils.convert_to_openai_messages(Message.user("hello"))

    assert {:ok, %{"role" => "user", "content" => ""}} =
             Utils.convert_to_openai_messages(Message.user(""))

    assert {:ok, [%{"role" => "developer", "content" => "rules"}]} =
             Utils.convert_to_openai_messages([{"developer", "rules"}])

    assert {:ok, [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}]} =
             Utils.convert_to_openai_messages([Message.user("hello")], text_format: :block)

    assert {:ok, [%{"type" => "message", "role" => "user"} = response_input]} =
             Utils.convert_to_openai_messages([Message.user("hello")], api: :responses)

    assert response_input["content"] == "hello"

    assert {:error, error} =
             Utils.convert_to_openai_messages([Message.user("hello")], text_format: :invalid)

    assert error.type == :invalid_openai_text_format
  end

  test "OpenAI chat conversion extracts tool-use blocks and preserves unicode arguments" do
    messages = [
      Message.assistant([
        %{type: :text, text: "checking"},
        %{
          type: :tool_use,
          id: "call-1",
          name: "create_customer",
          args: %{"customer_name" => "你好啊集团"}
        }
      ]),
      Message.user([
        %{type: :text, text: "see"},
        ContentBlock.image(%{data: "AAAA", mime_type: "image/png"}),
        %{type: :json, json: %{"key" => "value"}},
        %{type: :guard_content, guard_content: %{text: "protected"}},
        "loose text"
      ])
    ]

    assert {:ok, [assistant, user]} =
             Utils.convert_to_openai_messages(messages, text_format: :block)

    assert assistant["content"] == [%{"type" => "text", "text" => "checking"}]

    assert [%{"type" => "function", "id" => "call-1", "function" => function}] =
             assistant["tool_calls"]

    assert function["name"] == "create_customer"
    assert BeamWeaver.JSON.decode!(function["arguments"]) == %{"customer_name" => "你好啊集团"}
    assert function["arguments"] =~ "你好啊集团"

    assert [
             _,
             %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA"}},
             %{"type" => "text", "text" => json},
             %{"type" => "text", "text" => "protected"},
             %{"type" => "text", "text" => "loose text"}
           ] =
             user["content"]

    assert BeamWeaver.JSON.decode!(json) == %{"key" => "value"}
  end

  test "OpenAI chat conversion normalizes provider media, files, audio, and tool results" do
    image_data = Base.encode64("image-bytes")
    raw_image = <<1, 2, 3, 4>>

    messages = [
      Message.user([
        %{
          type: :text,
          text: "Here's an image:",
          cache_control: %{"type" => "ephemeral"}
        },
        ContentBlock.image(%{data: image_data, mime_type: "image/jpeg"})
      ]),
      Message.assistant([
        %{type: :tool_use, id: "call-1", name: "lookup", args: %{"q" => "beam"}}
      ]),
      Message.user([
        ContentBlock.tool_result(%{
          tool_call_id: "call-1",
          content: [ContentBlock.image(%{data: image_data, mime_type: "image/jpeg"})]
        })
      ]),
      Message.user([
        ContentBlock.image(%{data: Base.encode64(raw_image), mime_type: "image/jpeg"}),
        %{type: :media, mime_type: "image/png", data: raw_image},
        %{type: :file, base64: "pdf-bytes", mime_type: "application/pdf"},
        %{type: :file, file_id: "file-abc"},
        %{type: :audio, base64: "audio-bytes", mime_type: "audio/wav"},
        %{type: :reasoning, summary: []}
      ])
    ]

    assert {:ok, [user, assistant, tool, multimodal]} =
             Utils.convert_to_openai_messages(messages, text_format: :block)

    assert user["content"] == [
             %{"type" => "text", "text" => "Here's an image:"},
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/jpeg;base64,#{image_data}"}
             }
           ]

    assert assistant["content"] == []

    assert [%{"type" => "function", "id" => "call-1", "function" => function}] =
             assistant["tool_calls"]

    assert function["name"] == "lookup"
    assert BeamWeaver.JSON.decode!(function["arguments"]) == %{"q" => "beam"}

    assert tool == %{
             "role" => "tool",
             "tool_call_id" => "call-1",
             "content" => [
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "data:image/jpeg;base64,#{image_data}"}
               }
             ]
           }

    assert [
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/jpeg;base64,AQIDBA=="}
             },
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/png;base64,AQIDBA=="}
             },
             %{
               "type" => "file",
               "file" => %{
                 "file_data" => "data:application/pdf;base64,pdf-bytes",
                 "filename" => "LC_AUTOGENERATED"
               }
             },
             %{"type" => "file", "file" => %{"file_id" => "file-abc"}},
             %{
               "type" => "input_audio",
               "input_audio" => %{"data" => "audio-bytes", "format" => "wav"}
             },
             %{"type" => "reasoning", "summary" => []}
           ] = multimodal["content"]
  end

  test "approximate token counter includes role, name, content, images, tools, and usage scaling" do
    assert {:ok, 0} = Utils.count_tokens_approximately([])
    assert {:ok, 4} = Utils.count_tokens_approximately([Message.user("")])

    messages = [
      Message.user("Hello", name: "user"),
      Message.assistant("Hi there", name: "assistant")
    ]

    assert {:ok, 17} = Utils.count_tokens_approximately(messages)
    assert {:ok, 14} = Utils.count_tokens_approximately(messages, count_name: false)

    assert {:ok, 17} =
             Utils.count_tokens_approximately([
               %{"role" => "user", "content" => "Hello", "name" => "user"},
               %{"role" => "assistant", "content" => "Hi there", "name" => "assistant"}
             ])

    custom_length_messages = [
      Message.user("Hello world"),
      Message.assistant("Testing")
    ]

    assert {:ok, 14} =
             Utils.count_tokens_approximately(custom_length_messages, chars_per_token: 4)

    assert {:ok, 22} =
             Utils.count_tokens_approximately(custom_length_messages, chars_per_token: 2)

    assert {:ok, 90} =
             Utils.count_tokens_approximately(
               [
                 Message.user([
                   %{"type" => "text", "text" => "look"},
                   %{
                     "type" => "image_url",
                     "image_url" => %{"url" => "https://example.test/a.png"}
                   }
                 ])
               ],
               tokens_per_image: 85
             )

    assert {:ok, with_tools} =
             Utils.count_tokens_approximately([Message.user("Hello")],
               tools: [%{"type" => "function", "function" => %{"name" => "search"}}]
             )

    assert with_tools > 6

    scaled_messages = [
      Message.user("text"),
      Message.assistant("text",
        response_metadata: %{model_provider: "openai"},
        usage_metadata: %{total_tokens: 100}
      ),
      Message.user("text")
    ]

    assert {:ok, unscaled} = Utils.count_tokens_approximately(scaled_messages)

    assert {:ok, scaled} =
             Utils.count_tokens_approximately(scaled_messages, use_usage_metadata_scaling: true)

    assert scaled >= unscaled
  end

  test "message_chunk_to_message finalizes streamed assistant chunks" do
    chunk =
      [
        Messages.ai_chunk("hel", id: "msg-1"),
        Messages.ai_chunk("lo")
      ]
      |> BeamWeaver.Core.Messages.MessageChunk.merge_many()

    assert %Message{role: :assistant, content: "hello", id: "msg-1"} =
             Utils.message_chunk_to_message(chunk)
  end

  test "usage helpers add and subtract nested token metadata" do
    left = %{
      input_tokens: 10,
      output_tokens: 20,
      total_tokens: 30,
      input_token_details: %{audio: 5, cache_read: 1},
      output_token_details: %{reasoning: 10}
    }

    right = %{
      input_tokens: 5,
      output_tokens: 10,
      total_tokens: 15,
      input_token_details: %{audio: 3},
      output_token_details: %{reasoning: 5, audio: 1}
    }

    assert Utils.add_usage(nil, nil) == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

    assert Utils.add_usage(left, right) == %{
             input_tokens: 15,
             output_tokens: 30,
             total_tokens: 45,
             input_token_details: %{audio: 8, cache_read: 1},
             output_token_details: %{reasoning: 15, audio: 1}
           }

    assert Utils.subtract_usage(left, right) == %{
             input_tokens: 5,
             output_tokens: 10,
             total_tokens: 15,
             input_token_details: %{audio: 2, cache_read: 1},
             output_token_details: %{reasoning: 5, audio: 1}
           }

    assert Utils.subtract_usage(right, left).input_tokens == 0
  end

  test "native tool-call constructors feed chunk finalization" do
    chunk =
      Messages.ai_chunk("",
        tool_call_chunks: [
          Messages.tool_call_chunk(id: "call-1", index: 0, name: "search", args: ~s({"q":))
        ]
      )
      |> Messages.MessageChunk.merge(
        Messages.ai_chunk("",
          tool_call_chunks: [Messages.tool_call_chunk(index: 0, args: ~s|"beam"}|)]
        )
      )

    assert %Message{tool_calls: [%{id: "call-1", name: "search", args: %{"q" => "beam"}}]} =
             Utils.message_chunk_to_message(chunk)

    assert %{type: :tool_call, name: "search"} =
             Messages.tool_call(id: "call-2", name: "search", args: %{})

    assert %{type: :invalid_tool_call, error: "bad json"} =
             Messages.invalid_tool_call(id: "bad", name: "search", args: "{", error: "bad json")
  end

  test "filter excludes names, roles, ids, and tool calls by id while preserving valid history" do
    messages = [
      Message.system("system"),
      Message.user("hidden", id: "u1", name: "skip"),
      Message.assistant("call",
        id: "a1",
        tool_calls: [
          %ToolCall{id: "call-1", name: "search"},
          %ToolCall{id: "call-2", name: "math"}
        ]
      ),
      Message.tool("result", tool_call_id: "call-1"),
      Message.user("visible", id: "u2")
    ]

    assert {:ok, filtered} =
             Utils.filter(messages,
               exclude_names: ["skip"],
               exclude_tool_calls: ["call-1"],
               include_roles: [:system, :assistant, :tool, :user]
             )

    refute Enum.any?(filtered, &(&1.id == "u1"))
    refute Enum.any?(filtered, &(&1.role == :tool and &1.tool_call_id == "call-1"))
    assistant = Enum.find(filtered, &(&1.id == "a1"))
    assert assistant.tool_calls == [%ToolCall{id: "call-2", name: "math"}]

    assert {:ok, human_messages} = Utils.filter(messages, include_types: ["human"])
    assert Enum.map(human_messages, & &1.id) == ["u1", "u2"]
    assert {:ok, [%Message{id: "a1"}]} = Utils.filter(messages, include_types: [:ai])
  end

  test "filter removes matching tool-use content blocks with excluded tool calls" do
    messages = [
      Message.user("bar", id: "u1"),
      Message.assistant(
        [
          %{type: :text, text: "bar-response"},
          %{type: :tool_use, name: "foo", id: "call-1"},
          %{type: :tool_use, name: "bar", id: "call-2"}
        ],
        id: "a1",
        tool_calls: [
          %ToolCall{id: "call-1", name: "foo", args: %{}},
          %ToolCall{id: "call-2", name: "bar", args: %{}}
        ]
      ),
      Message.tool("foo result", tool_call_id: "call-1"),
      Message.tool("bar result", tool_call_id: "call-2")
    ]

    assert {:ok, filtered} = Utils.filter(messages, exclude_tool_calls: ["call-1"])
    assert [_, assistant, tool] = filtered
    assert assistant.tool_calls == [%ToolCall{id: "call-2", name: "bar", args: %{}}]

    assert assistant.content == [
             %{type: :text, text: "bar-response"},
             %{type: :tool_use, name: "bar", id: "call-2"}
           ]

    assert tool.tool_call_id == "call-2"

    assert {:ok, only_user} =
             Utils.filter(messages, exclude_tool_calls: ["call-1", "call-2"])

    assert Enum.map(only_user, & &1.role) == [:user]
  end

  test "merge_runs merges consecutive non-tool messages and accumulates usage metadata" do
    messages = [
      Message.user("one", usage_metadata: %{input_tokens: 1}),
      Message.user("two", usage_metadata: %{input_tokens: 2}),
      Message.tool("tool", tool_call_id: "call-1"),
      Message.tool("tool2", tool_call_id: "call-2")
    ]

    assert {:ok, [user, tool1, tool2]} = Utils.merge_runs(messages, chunk_separator: " ")
    assert user.content == "one two"
    assert user.usage_metadata == %{input_tokens: 3}
    assert tool1.content == "tool"
    assert tool2.content == "tool2"
  end

  test "merge_runs preserves first response metadata while accumulating usage" do
    messages = [
      Message.assistant("one",
        response_metadata: %{request_id: "first"},
        usage_metadata: %{output_tokens: 1}
      ),
      Message.assistant("two",
        response_metadata: %{request_id: "second"},
        usage_metadata: %{output_tokens: 2}
      )
    ]

    assert {:ok, [merged]} = Utils.merge_runs(messages)
    assert merged.content == "one\ntwo"
    assert merged.response_metadata == %{request_id: "first"}
    assert merged.usage_metadata == %{output_tokens: 3}
  end

  test "trim supports last strategy with include-system/start-on and first strategy with partial text" do
    messages = [
      Message.system("system prompt"),
      Message.user("one two three"),
      Message.assistant("four five six"),
      Message.user("seven eight")
    ]

    assert {:ok, trimmed} =
             Utils.trim(messages,
               max_tokens: 4,
               strategy: :last,
               include_system: true,
               start_on: :user,
               token_counter: :approximate
             )

    assert Enum.map(trimmed, & &1.role) == [:system, :user]
    assert List.last(trimmed).content == "seven eight"

    assert {:ok, [first]} =
             Utils.trim(messages,
               max_tokens: 1,
               strategy: :first,
               allow_partial: true,
               token_counter: :approximate
             )

    assert first.content == "system"
  end

  test "trim accepts tokenizer counters and preserves assistant/tool-message adjacency" do
    tokenizer =
      %StaticVocabulary{
        vocabulary: %{"call" => 1, "tool " => 2, "result" => 3, "final" => 4}
      }

    messages = [
      Message.assistant("call",
        tool_calls: [%ToolCall{id: "call-1", name: "search", args: %{}}]
      ),
      Message.tool("tool result", tool_call_id: "call-1"),
      Message.user("final")
    ]

    assert {:ok, trimmed_pair} =
             Utils.trim(messages,
               max_tokens: 4,
               strategy: :last,
               token_counter: {:tokenizer, tokenizer}
             )

    assert Enum.map(trimmed_pair, & &1.role) == [:assistant, :tool, :user]
    assert [%ToolCall{id: "call-1"}] = hd(trimmed_pair).tool_calls

    assert {:ok, trimmed_orphan_removed} =
             Utils.trim(messages,
               max_tokens: 3,
               strategy: :last,
               token_counter: {:tokenizer, tokenizer}
             )

    refute Enum.any?(trimmed_orphan_removed, &(&1.role == :tool))
    assert Enum.map(trimmed_orphan_removed, & &1.role) == [:user]
  end

  test "trim supports human aliases and partial structured text blocks" do
    token_counter = fn
      %Message{content: content} when is_binary(content) ->
        content |> String.split(~r/\s+/, trim: true) |> length()

      %Message{content: content} when is_list(content) ->
        Enum.reduce(content, 0, fn
          %{type: :text, text: text}, acc ->
            acc + (text |> String.split(~r/\s+/, trim: true) |> length())

          _block, acc ->
            acc + 1
        end)
    end

    structured = [
      Message.assistant([
        %{"type" => "text", "text" => "first second third fourth"},
        %{"type" => "text", "text" => "fifth sixth seventh eighth"}
      ])
    ]

    assert {:ok, [partial]} =
             Utils.trim(structured,
               max_tokens: 4,
               strategy: :first,
               allow_partial: true,
               token_counter: token_counter
             )

    assert partial.content == [%{type: :text, text: "first second third fourth"}]

    messages = [
      Message.user("first human"),
      Message.assistant("assistant response"),
      Message.user("second human")
    ]

    assert {:ok, [last]} =
             Utils.trim(messages,
               max_tokens: 2,
               strategy: :last,
               start_on: :human,
               token_counter: token_counter
             )

    assert last.content == "second human"
  end

  test "get_buffer_string formats role-prefixed chat history" do
    messages = [
      Message.system("rules"),
      Message.user("question"),
      Message.assistant("answer"),
      Message.tool("result", tool_call_id: "call-1")
    ]

    assert {:ok, buffer} = Utils.get_buffer_string(messages, human_prefix: "User")

    assert buffer == """
           System: rules
           User: question
           AI: answer
           Tool: result\
           """
  end

  test "get_buffer_string supports separators, tool calls, and XML formatting" do
    messages = [
      Message.user("What's the weather?"),
      Message.assistant("Let me check",
        tool_calls: [
          %ToolCall{id: "call_1", name: "get_weather", args: %{"city" => "NYC"}}
        ]
      )
    ]

    assert {:ok, prefix} = Utils.get_buffer_string(messages, message_separator: " | ")
    assert prefix =~ "Human: What's the weather?"
    assert prefix =~ "AI: Let me check"
    assert prefix =~ "get_weather"
    assert prefix =~ "NYC"
    assert prefix =~ " | "

    assert {:ok, xml} = Utils.get_buffer_string(messages, format: :xml)

    assert xml == """
           <message type="human">What's the weather?</message>
           <message type="ai">
             <content>Let me check</content>
             <tool_call id="call_1" name="get_weather">{"city":"NYC"}</tool_call>
           </message>\
           """

    assert {:error, error} = Utils.get_buffer_string(messages, format: :markdown)
    assert error.type == :invalid_buffer_format
  end

  test "get_buffer_string XML escapes content and formats supported content blocks" do
    messages = [
      Message.system("Is 5 < 10 & 10 > 5?"),
      Message.user([
        %{"type" => "text", "text" => "hello <world>"},
        %{"type" => "reasoning", "reasoning" => "because a > b"},
        %{"type" => "image", "url" => "https://example.test/image?a=1&b=2"},
        %{"type" => "image", "url" => "data:image/png;base64,AAAA"},
        %{"type" => "unknown", "value" => "skipped"}
      ])
    ]

    assert {:ok, xml} = Utils.get_buffer_string(messages, format: "xml")

    assert xml == """
           <message type="system">Is 5 &lt; 10 &amp; 10 &gt; 5?</message>
           <message type="human">hello &lt;world&gt; <reasoning>because a &gt; b</reasoning> <image url="https://example.test/image?a=1&amp;b=2" /></message>\
           """
  end

  test "get_buffer_string XML formats server tool calls, results, media, and long text blocks" do
    long_text = String.duplicate("x", 505)

    messages = [
      Message.assistant(
        [
          %{"type" => "text-plain", "text" => long_text},
          %{"type" => "audio", "file_id" => "audio-1"},
          %{"type" => "video", "url" => "https://example.test/video?a=1&b=2"},
          %{
            "type" => "server_tool_call",
            "id" => "srv-1",
            "name" => "search",
            "args" => %{q: "<beam>"}
          },
          %{
            "type" => "server_tool_result",
            "tool_call_id" => "srv-1",
            "status" => "completed",
            "output" => %{ok: true}
          }
        ],
        server_tool_calls: [%{id: "srv-2", name: "lookup", args: %{query: "docs"}}],
        server_tool_results: [%{tool_call_id: "srv-2", status: "failed", output: "missing"}]
      )
    ]

    assert {:ok, xml} = Utils.get_buffer_string(messages, format: :xml)

    assert xml =~ String.duplicate("x", 500) <> "..."
    assert xml =~ ~s(<audio file_id="audio-1" />)
    assert xml =~ ~s(<video url="https://example.test/video?a=1&amp;b=2" />)

    assert xml =~
             ~s(<server_tool_call id="srv-1" name="search">{"q":"&lt;beam&gt;"}</server_tool_call>)

    assert xml =~
             ~s(<server_tool_result tool_call_id="srv-1" status="completed">{"ok":true}</server_tool_result>)

    assert xml =~
             ~s(<server_tool_call id="srv-2" name="lookup">{"query":"docs"}</server_tool_call>)

    assert xml =~
             ~s(<server_tool_result tool_call_id="srv-2" status="failed">"missing"</server_tool_result>)
  end

  test "OpenAI provider protocols encode and decode messages with usage metadata" do
    message = Message.user([%{type: :text, text: "hello"}])

    assert {:ok, %{"type" => "message", "role" => "user"}} =
             EncodeMessage.encode(message, provider: :openai)

    response = %{
      "id" => "resp-1",
      "model" => "gpt",
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "done"}]}
      ],
      "usage" => %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7}
    }

    assert {:ok, decoded} = DecodeMessage.decode(response, provider: :openai)
    assert Message.text(decoded) == "done"
    assert decoded.usage_metadata == %{input_tokens: 3, output_tokens: 4, total_tokens: 7}
    assert decoded.response_metadata.model == "gpt"
  end
end
