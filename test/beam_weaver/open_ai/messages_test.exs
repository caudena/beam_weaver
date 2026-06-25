defmodule BeamWeaver.OpenAI.MessagesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.MessageLike
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.OpenAI.Messages

  test "converts BeamWeaver messages into Responses API input items" do
    messages = [
      Message.system("stay brief"),
      Message.user([%{type: :text, text: "hello"}]),
      Message.tool("42", tool_call_id: "call_weather")
    ]

    assert {:ok, input} = Messages.to_responses_input(messages)

    assert input == [
             %{"type" => "message", "role" => "system", "content" => "stay brief"},
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "hello"}]
             },
             %{
               "type" => "function_call_output",
               "call_id" => "call_weather",
               "output" => "42"
             }
           ]
  end

  test "rejects tool messages that cannot be linked back to a function call" do
    assert {:error, error} = Messages.to_responses_input([Message.tool("orphaned")])
    assert error.type == :invalid_tool_message
  end

  test "converts user text and image blocks into Responses API input parts" do
    assert {:ok, input} =
             Messages.to_responses_input([
               Message.user([
                 %{
                   type: :text,
                   text: "What's in this image?"
                 },
                 %{
                   type: :image_url,
                   image_url: %{
                     url: "https://example.test/image.jpg",
                     detail: "high"
                   }
                 }
               ])
             ])

    assert [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "What's in this image?"},
                 %{
                   "type" => "input_image",
                   "image_url" => "https://example.test/image.jpg",
                   "detail" => "high"
                 }
               ]
             }
           ] = input
  end

  test "converts an image_url block whose image_url is a bare string" do
    assert {:ok, input} =
             Messages.to_responses_input([
               Message.user([
                 %{type: :image_url, image_url: "https://example.test/image.jpg"}
               ])
             ])

    assert [
             %{
               "content" => [
                 %{"type" => "input_image", "image_url" => "https://example.test/image.jpg"}
               ]
             }
           ] = input
  end

  test "converts Responses API image, audio, and file data blocks" do
    # Upstream reference:
    # - test_convert_to_openai_data_block
    assert {:ok, input} =
             Messages.to_responses_input([
               Message.user([
                 %{type: :image, url: "https://example.test/image.png"},
                 %{type: :image, base64: "image-bytes", mime_type: "image/png"},
                 %{type: :audio, base64: "audio-bytes", mime_type: "audio/wav"},
                 %{
                   type: :file,
                   base64: "pdf-bytes",
                   mime_type: "application/pdf",
                   filename: "report.pdf"
                 },
                 %{type: :file, file_id: "file-abc123"},
                 %{type: :file, url: "https://example.test/report.pdf"}
               ])
             ])

    assert [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{"type" => "input_image", "image_url" => "https://example.test/image.png"},
                 %{"type" => "input_image", "image_url" => "data:image/png;base64,image-bytes"},
                 %{
                   "type" => "input_audio",
                   "input_audio" => %{"data" => "audio-bytes", "format" => "wav"}
                 },
                 %{
                   "type" => "input_file",
                   "file_data" => "data:application/pdf;base64,pdf-bytes",
                   "filename" => "report.pdf"
                 },
                 %{"type" => "input_file", "file_id" => "file-abc123"},
                 %{"type" => "input_file", "file_url" => "https://example.test/report.pdf"}
               ]
             }
           ] = input
  end

  test "converts typed BeamWeaver content block structs to Responses API input parts" do
    assert {:ok, input} =
             Messages.to_responses_input([
               Message.user([
                 ContentBlock.image(%{url: "https://example.test/cat.png"}),
                 ContentBlock.image(%{data: "image-bytes", mime_type: "image/jpeg"}),
                 ContentBlock.audio(%{data: "audio-bytes", mime_type: "audio/mp3"}),
                 ContentBlock.file(%{
                   data: "pdf-bytes",
                   mime_type: "application/pdf",
                   filename: "typed.pdf"
                 }),
                 ContentBlock.file(%{file_id: "file-typed"})
               ])
             ])

    assert [
             %{
               "content" => [
                 %{"type" => "input_image", "image_url" => "https://example.test/cat.png"},
                 %{"type" => "input_image", "image_url" => "data:image/jpeg;base64,image-bytes"},
                 %{
                   "type" => "input_audio",
                   "input_audio" => %{"data" => "audio-bytes", "format" => "mp3"}
                 },
                 %{
                   "type" => "input_file",
                   "file_data" => "data:application/pdf;base64,pdf-bytes",
                   "filename" => "typed.pdf"
                 },
                 %{"type" => "input_file", "file_id" => "file-typed"}
               ]
             }
           ] = input
  end

  test "strict structured output format closes nested schemas and preserves optional fields as nullable" do
    schema = %{
      type: "object",
      properties: %{
        required_name: %{type: "string"},
        optional_count: %{type: "number"},
        event_date: %{type: "string", format: "date"},
        crm_updates: %{
          type: "object",
          properties: %{
            company_to_create: %{
              type: "object",
              properties: %{
                name: %{type: "string"},
                properties: %{type: "object"}
              },
              required: [:name]
            }
          },
          required: []
        }
      },
      required: [:required_name]
    }

    format = Messages.structured_output_format("narrative_output", schema)
    rendered = format["schema"]

    assert format["strict"] == true
    assert rendered["additionalProperties"] == false

    assert MapSet.new(rendered["required"]) ==
             MapSet.new(["required_name", "optional_count", "event_date", "crm_updates"])

    assert rendered["properties"]["optional_count"]["type"] == ["number", "null"]
    refute Map.has_key?(rendered["properties"]["event_date"], "format")
    assert rendered["properties"]["event_date"]["type"] == ["string", "null"]

    crm_updates = rendered["properties"]["crm_updates"]

    assert [%{"type" => "object"} = crm_updates_schema, %{"type" => "null"}] =
             crm_updates["anyOf"]

    crm_updates = crm_updates_schema
    assert crm_updates["additionalProperties"] == false
    assert crm_updates["required"] == ["company_to_create"]

    company_to_create = crm_updates["properties"]["company_to_create"]

    assert [%{"type" => "object"} = company_to_create_schema, %{"type" => "null"}] =
             company_to_create["anyOf"]

    company_to_create = company_to_create_schema
    assert company_to_create["additionalProperties"] == false
    assert MapSet.new(company_to_create["required"]) == MapSet.new(["name", "properties"])
    assert company_to_create["properties"]["name"]["type"] == "string"

    assert [%{"type" => "object"} = properties_schema, %{"type" => "null"}] =
             company_to_create["properties"]["properties"]["anyOf"]

    assert properties_schema["properties"] == %{}
    assert properties_schema["required"] == []
    assert properties_schema["additionalProperties"] == false
  end

  test "strict structured output format drops stale required keys and unsupported composition keywords" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "known" => %{"type" => "string", "allOf" => [%{"type" => "string"}]},
        "maybe_payload" => %{
          "type" => ["object"],
          "properties" => %{"id" => %{"type" => "string"}},
          "required" => ["id"],
          "dependentRequired" => %{"id" => ["other"]}
        }
      },
      "required" => ["known", "removed"]
    }

    rendered = Messages.structured_output_format("strict_shape", schema)["schema"]

    assert rendered["required"] == ["known", "maybe_payload"]
    refute Map.has_key?(rendered["properties"]["known"], "allOf")

    assert [%{"type" => ["object"]} = payload_schema, %{"type" => "null"}] =
             rendered["properties"]["maybe_payload"]["anyOf"]

    refute Map.has_key?(payload_schema, "dependentRequired")
    assert payload_schema["additionalProperties"] == false
    assert payload_schema["required"] == ["id"]
  end

  test "converts assistant text and tool calls into Responses API output items" do
    message =
      Message.assistant("I'll check the weather for you.",
        tool_calls: [
          %ToolCall{
            id: "call_123",
            name: "get_weather",
            args: %{"location" => "San Francisco"}
          }
        ]
      )

    assert {:ok, input} = Messages.to_responses_input([message])

    assert [
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "I'll check the weather for you.",
                   "annotations" => []
                 }
               ]
             },
             %{
               "type" => "function_call",
               "call_id" => "call_123",
               "name" => "get_weather",
               "arguments" => ~s({"location":"San Francisco"})
             }
           ] = input
  end

  test "strips internal provider fields when replaying Responses output items" do
    message =
      Message.assistant([
        %{
          type: :reasoning,
          id: "rs_1",
          reasoning: "private summary text",
          summary: [%{"type" => "summary_text", "text" => "summary"}],
          raw_provider_block: %{"type" => "reasoning", "id" => "rs_1", "summary" => []}
        },
        %{
          type: :image_generation_call,
          id: "ig_1",
          result: "...",
          raw_provider_block: %{"type" => "image_generation_call", "id" => "ig_1"}
        }
      ])

    assert {:ok, input} = Messages.to_responses_input([message])

    assert [
             %{"type" => "reasoning", "id" => "rs_1", "summary" => [%{"text" => "summary", "type" => "summary_text"}]},
             %{"type" => "image_generation_call", "id" => "ig_1", "result" => "..."}
           ] = input

    refute input |> BeamWeaver.JSON.encode!() |> String.contains?("raw_provider_block")
    refute input |> BeamWeaver.JSON.encode!() |> String.contains?("private summary text")
  end

  test "store false sanitizes replay-only Responses item ids and non-replayable blocks" do
    message =
      Message.assistant([
        %{type: :text, id: "msg_1", text: "cached answer"},
        %{type: :reasoning, id: "rs_plain", summary: []},
        %{type: :reasoning, id: "rs_enc", encrypted_content: "encrypted-reasoning", summary: []},
        %{type: :image_generation_call, id: "ig_empty", status: "completed"},
        %{type: :image_generation_call, id: "ig_result", result: "..."},
        %{
          type: :function_call,
          id: "fc_123",
          call_id: "call_123",
          name: "lookup",
          arguments: %{"query" => "beam"}
        }
      ])

    assert {:ok, input} = Messages.to_responses_input([message], store: false)

    assert [
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [
                 %{"type" => "output_text", "text" => "cached answer", "annotations" => []}
               ]
             },
             %{"type" => "reasoning", "summary" => [], "encrypted_content" => "encrypted-reasoning"},
             %{"type" => "image_generation_call", "result" => "..."},
             %{
               "type" => "function_call",
               "call_id" => "call_123",
               "name" => "lookup",
               "arguments" => ~s({"query":"beam"})
             }
           ] = input

    encoded = BeamWeaver.JSON.encode!(input)
    refute encoded =~ "msg_1"
    refute encoded =~ "rs_plain"
    refute encoded =~ "rs_enc"
    refute encoded =~ "ig_empty"
    refute encoded =~ "ig_result"
    refute encoded =~ "fc_123"
  end

  test "preserves OpenAI apply_patch output items for replay" do
    message =
      Message.assistant([
        %{
          type: :apply_patch_call,
          id: "apc_123",
          status: "completed",
          patch: "*** Begin Patch\n*** End Patch\n"
        },
        %{
          type: :apply_patch_call_output,
          id: "apco_123",
          status: "completed",
          output: "Success."
        }
      ])

    assert {:ok, input} = Messages.to_responses_input([message])

    assert input == [
             %{
               "type" => "apply_patch_call",
               "id" => "apc_123",
               "status" => "completed",
               "patch" => "*** Begin Patch\n*** End Patch\n"
             },
             %{
               "type" => "apply_patch_call_output",
               "id" => "apco_123",
               "status" => "completed",
               "output" => "Success."
             }
           ]
  end

  test "strips internal provider fields from unknown output blocks on replay" do
    message =
      Message.assistant([
        %BeamWeaver.Core.ContentBlock.Unknown{
          provider_type: "image_generation_call",
          value: %{
            "type" => "image_generation_call",
            "id" => "ig_2",
            "result" => "...",
            "raw_provider_block" => %{"type" => "image_generation_call"}
          }
        }
      ])

    assert {:ok, [%{"type" => "image_generation_call", "id" => "ig_2", "result" => "..."}]} =
             Messages.to_responses_input([message])
  end

  test "keeps assistant function_call content blocks without duplicating tool_calls" do
    message =
      Message.assistant(
        [
          %{type: :text, text: "Checking."},
          %{
            type: :function_call,
            id: "fc_456",
            call_id: "call_123",
            name: "get_weather",
            arguments: ~s({"location":"San Francisco"})
          }
        ],
        tool_calls: [
          %ToolCall{id: "call_123", name: "get_weather", args: %{"location" => "SF"}}
        ]
      )

    assert {:ok, input} = Messages.to_responses_input([message])

    assert [
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [%{"type" => "output_text", "text" => "Checking."}]
             },
             %{
               "type" => "function_call",
               "id" => "fc_456",
               "call_id" => "call_123",
               "name" => "get_weather",
               "arguments" => ~s({"location":"San Francisco"})
             }
           ] = input
  end

  test "groups assistant v3 content blocks by Responses message id" do
    message =
      Message.assistant([
        %{type: :text, text: "foo", id: "msg_123"},
        %{type: :text, text: "bar", id: "msg_123"},
        %{type: :refusal, refusal: "I refuse.", id: "msg_123"},
        %{type: :text, text: "baz", id: "msg_234"}
      ])

    assert {:ok, input} = Messages.to_responses_input([message])

    assert [
             %{
               "type" => "message",
               "role" => "assistant",
               "id" => "msg_123",
               "content" => [
                 %{"type" => "output_text", "text" => "foo", "annotations" => []},
                 %{"type" => "output_text", "text" => "bar", "annotations" => []},
                 %{"type" => "refusal", "refusal" => "I refuse."}
               ]
             },
             %{
               "type" => "message",
               "role" => "assistant",
               "id" => "msg_234",
               "content" => [
                 %{"type" => "output_text", "text" => "baz", "annotations" => []}
               ]
             }
           ] = input
  end

  test "converts BeamWeaver tools into OpenAI function declarations" do
    tool =
      Tool.from_function!(
        name: "get_weather",
        description: "Get the current weather",
        input_schema: %{
          type: "object",
          properties: %{city: %{type: "string"}},
          required: [:city]
        },
        handler: fn input, _opts -> input end
      )

    assert Messages.tool_to_openai(tool) == %{
             "type" => "function",
             "name" => "get_weather",
             "description" => "Get the current weather",
             "parameters" => %{
               "type" => "object",
               "properties" => %{"city" => %{"type" => "string"}},
               "required" => ["city"]
             }
           }
  end

  test "extracts assistant text and tool calls from a Responses API result" do
    response = %{
      "id" => "resp_123",
      "model" => "gpt-5.4-mini",
      "output" => [
        %{
          "type" => "message",
          "content" => [
            %{"type" => "output_text", "text" => "Let me check."}
          ]
        },
        %{
          "type" => "function_call",
          "call_id" => "call_weather",
          "name" => "get_weather",
          "arguments" => ~s({"city":"Paris"})
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 6}
    }

    assert {:ok, message} = Messages.response_to_message(response)
    assert message.role == :assistant
    assert Message.text(message) == "Let me check."
    assert BeamWeaver.MapShape.assert_atom_keys!(message.metadata)
    assert BeamWeaver.MapShape.assert_atom_keys!(message.response_metadata)
    assert BeamWeaver.MapShape.assert_string_keys!(message.metadata.raw_provider_response)
    assert message.metadata.id == "resp_123"
    assert message.metadata.raw_provider_response == response

    assert [
             %ToolCall{
               call_id: "call_weather",
               name: "get_weather",
               args: %{"city" => "Paris"}
             }
           ] = message.tool_calls

    assert BeamWeaver.MapShape.assert_string_keys!(hd(message.tool_calls).args)
  end

  test "maps Responses API usage token details without dropping explicit zero totals" do
    assert {:ok, message} =
             Messages.response_to_message(%{
               "id" => "resp_usage",
               "output" => [],
               "usage" => %{
                 "input_tokens" => 100,
                 "input_tokens_details" => %{"cached_tokens" => 50, "flex" => 100},
                 "output_tokens" => 50,
                 "output_tokens_details" => %{
                   "reasoning_tokens" => 10,
                   "accepted_prediction_tokens" => 4,
                   "rejected_prediction_tokens" => 2,
                   "flex" => 40,
                   "flex_reasoning" => 10
                 },
                 "total_tokens" => 0
               }
             })

    assert message.usage_metadata == %{
             input_tokens: 100,
             output_tokens: 50,
             total_tokens: 0,
             input_token_details: %{cache_read: 50, flex: 100},
             output_token_details: %{
               reasoning: 10,
               accepted_prediction: 4,
               rejected_prediction: 2,
               flex: 40,
               flex_reasoning: 10
             }
           }
  end

  test "preserves Responses API v3 output blocks and invalid function arguments" do
    response = %{
      "id" => "resp_123",
      "model" => "gpt-5.4",
      "metadata" => %{"trace" => "abc"},
      "incomplete_details" => %{"reason" => "max_output_tokens"},
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_123",
          "content" => [
            %{"type" => "output_text", "text" => "I found this.", "annotations" => []}
          ]
        },
        %{
          "type" => "web_search_call",
          "id" => "web_123",
          "status" => "completed",
          "action" => %{"type" => "search", "query" => "weather"}
        },
        %{
          "type" => "file_search_call",
          "id" => "file_123",
          "status" => "completed",
          "queries" => ["weather"],
          "results" => [
            %{"file_id" => "file_a", "filename" => "weather.txt", "score" => 0.95}
          ]
        },
        %{
          "type" => "function_call",
          "id" => "func_123",
          "call_id" => "call_123",
          "name" => "get_weather",
          "arguments" => ~s({"location":"Paris")
        },
        %{
          "type" => "message",
          "id" => "msg_456",
          "content" => [
            %{"type" => "refusal", "refusal" => "I cannot provide more detail."}
          ]
        }
      ]
    }

    assert {:ok, message} = Messages.response_to_message(response)

    assert [
             %{type: :text, id: "msg_123", text: "I found this."},
             %{type: :web_search_call, id: "web_123"},
             %{
               type: :file_search_call,
               id: "file_123",
               queries: ["weather"],
               results: [%{"file_id" => "file_a", "filename" => "weather.txt", "score" => 0.95}]
             },
             %{
               type: :tool_call,
               provider_id: "func_123",
               call_id: "call_123",
               name: "get_weather",
               arguments: ~s({"location":"Paris")
             },
             %{
               type: :refusal,
               id: "msg_456",
               refusal: "I cannot provide more detail."
             }
           ] = message.content

    assert message.metadata.provider_metadata == %{"trace" => "abc"}
    assert message.metadata.incomplete_details == %{"reason" => "max_output_tokens"}
    assert message.metadata.status == "completed"

    assert message.tool_calls == []

    assert [
             %{
               type: :invalid_tool_call,
               id: "call_123",
               provider_id: "func_123",
               call_id: "call_123",
               name: "get_weather",
               args: ~s({"location":"Paris")
             }
           ] = message.metadata[:invalid_tool_calls]
  end

  test "preserves Responses reasoning summaries and text annotations" do
    # Upstream reference:
    # - test_convert_to_v1_from_responses
    response = %{
      "id" => "resp_annotations",
      "output" => [
        %{
          "type" => "reasoning",
          "id" => "rs_1",
          "summary" => [
            %{"type" => "summary_text", "text" => "looked up docs"}
          ]
        },
        %{
          "type" => "message",
          "id" => "msg_1",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "See docs.",
              "annotations" => [
                %{"type" => "url_citation", "url" => "https://example.test/docs"},
                %{"type" => "file_citation", "file_id" => "file_123", "filename" => "docs.pdf"}
              ]
            }
          ]
        }
      ]
    }

    assert {:ok, message} = Messages.response_to_message(response)

    assert [
             %{
               type: :reasoning,
               id: "rs_1",
               reasoning: "looked up docs",
               summary: [%{"type" => "summary_text", "text" => "looked up docs"}]
             },
             %{
               type: :text,
               id: "msg_1",
               text: "See docs.",
               annotations: [
                 %{"type" => "url_citation", "url" => "https://example.test/docs"},
                 %{"type" => "file_citation", "file_id" => "file_123", "filename" => "docs.pdf"}
               ]
             }
           ] = message.content

    assert message.metadata.output == response["output"]
    assert message.usage_metadata == nil
  end

  test "preserves mixed Responses output items and unknown provider blocks" do
    # Upstream reference:
    # - test_convert_to_v1_from_responses, adjusted for BeamWeaver's raw provider block retention.
    response = %{
      "id" => "resp_mixed",
      "model" => "gpt-5.4",
      "output" => [
        %{"type" => "reasoning", "id" => "rs_empty", "summary" => []},
        %{
          "type" => "reasoning",
          "id" => "rs_summary",
          "summary" => [
            %{"type" => "summary_text", "text" => "foo bar"},
            %{"type" => "summary_text", "text" => "baz"}
          ]
        },
        %{
          "type" => "function_call",
          "id" => "fc_123",
          "call_id" => "call_123",
          "name" => "get_weather",
          "arguments" => ~s({"location":"San Francisco"})
        },
        %{
          "type" => "message",
          "id" => "msg_1",
          "content" => [
            %{"type" => "output_text", "text" => "Hello ", "annotations" => []},
            %{
              "type" => "output_text",
              "text" => "world",
              "annotations" => [
                %{"type" => "url_citation", "url" => "https://example.com"},
                %{
                  "type" => "file_citation",
                  "filename" => "my doc",
                  "index" => 1,
                  "file_id" => "file_123"
                },
                %{"bar" => "baz"}
              ]
            }
          ]
        },
        %{"type" => "image_generation_call", "id" => "ig_123", "result" => "..."},
        %{
          "type" => "file_search_call",
          "id" => "fs_123",
          "queries" => ["query for file search"],
          "results" => [%{"file_id" => "file-123"}],
          "status" => "completed"
        },
        %{"type" => "something_else", "foo" => "bar"}
      ]
    }

    assert {:ok, message} = Messages.response_to_message(response)

    assert [
             %{type: :reasoning, id: "rs_empty", summary: []},
             %{
               type: :reasoning,
               id: "rs_summary",
               reasoning: "foo barbaz",
               summary: [
                 %{"type" => "summary_text", "text" => "foo bar"},
                 %{"type" => "summary_text", "text" => "baz"}
               ]
             },
             %{
               type: :tool_call,
               provider_id: "fc_123",
               call_id: "call_123",
               name: "get_weather"
             },
             %{type: :text, text: "Hello ", annotations: []},
             %{
               type: :text,
               text: "world",
               annotations: [
                 %{"type" => "url_citation", "url" => "https://example.com"},
                 %{
                   "type" => "file_citation",
                   "filename" => "my doc",
                   "index" => 1,
                   "file_id" => "file_123"
                 },
                 %{"bar" => "baz"}
               ]
             },
             %{type: :image_generation_call, id: "ig_123", result: "..."},
             %{
               type: :file_search_call,
               id: "fs_123",
               queries: ["query for file search"],
               results: [%{"file_id" => "file-123"}],
               status: "completed"
             }
           ] = message.content

    assert [
             %ToolCall{
               id: "call_123",
               provider_id: "fc_123",
               call_id: "call_123",
               name: "get_weather",
               args: %{"location" => "San Francisco"}
             }
           ] = message.tool_calls

    assert Enum.any?(message.metadata.output, &(&1["type"] == "something_else"))
  end

  test "Chat Completions translator handles OpenAI input data blocks" do
    # Upstream reference:
    # - test_convert_to_v1_from_openai_input and test_convert_to_openai_data_block.
    alias BeamWeaver.OpenAI.ChatCompletions.Messages, as: ChatMessages

    assert {:ok, [openai_message]} =
             ChatMessages.to_openai_messages([
               Message.user([
                 %{type: :text, text: "Hello"},
                 %{type: :image, url: "https://example.com/image.png"},
                 %{
                   type: :image,
                   base64: "/9j/4AAQSkZJRg...",
                   mime_type: "image/jpeg"
                 },
                 %{type: :audio, base64: "<base64 string>", mime_type: "audio/wav"},
                 %{
                   type: :file,
                   base64: "<base64 string>",
                   mime_type: "application/pdf",
                   filename: "draconomicon.pdf"
                 },
                 %{type: :file, file_id: "<file id>"}
               ])
             ])

    assert openai_message["content"] == [
             %{"type" => "text", "text" => "Hello"},
             %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/image.png"}},
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/jpeg;base64,/9j/4AAQSkZJRg..."}
             },
             %{
               "type" => "input_audio",
               "input_audio" => %{"data" => "<base64 string>", "format" => "wav"}
             },
             %{
               "type" => "file",
               "file" => %{
                 "file_data" => "data:application/pdf;base64,<base64 string>",
                 "filename" => "draconomicon.pdf"
               }
             },
             %{"type" => "file", "file" => %{"file_id" => "<file id>"}}
           ]
  end

  test "Chat Completions translator preserves provider tool call ids for assistant/tool continuity" do
    alias BeamWeaver.OpenAI.ChatCompletions.Messages, as: ChatMessages

    messages = [
      Message.assistant("",
        tool_calls: [
          %ToolCall{
            id: "task_0",
            provider_id: "task:0",
            call_id: "task:0",
            name: "task",
            args: %{"description" => "run subagent"}
          }
        ]
      ),
      Message.tool("done", tool_call_id: "task:0")
    ]

    assert {:ok, openai_messages} = ChatMessages.to_openai_messages(messages)

    assert [
             %{
               "role" => "assistant",
               "tool_calls" => [
                 %{
                   "id" => "task:0",
                   "function" => %{"name" => "task"}
                 }
               ]
             },
             %{"role" => "tool", "tool_call_id" => "task:0"}
           ] = openai_messages
  end

  test "OpenAI dict roles round-trip through native message structs" do
    alias BeamWeaver.OpenAI.ChatCompletions.Messages, as: ChatMessages

    raw_tool_call = %{
      "id" => "call_wm0",
      "function" => %{"name" => "GenerateUsername", "arguments" => ~s({"name":"Sally"})},
      "type" => "function"
    }

    raw_invalid_tool_call = %{
      "id" => "call_bad",
      "function" => %{"name" => "GenerateUsername", "arguments" => "oops"},
      "type" => "function"
    }

    assert {:ok, function_message} =
             MessageLike.to_message(%{
               "role" => "function",
               "name" => "test_function",
               "content" => ~s({"result":"Example #1"})
             })

    assert function_message.role == :assistant
    assert function_message.metadata == %{}

    assert {:ok, developer_message} =
             MessageLike.to_message(%{"role" => "developer", "content" => "dev"})

    assert developer_message.role == :system
    assert developer_message.metadata.openai_role == :developer

    assert {:ok, assistant_tool_call} =
             MessageLike.to_message(%{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [raw_invalid_tool_call, raw_tool_call]
             })

    assert assistant_tool_call.content == ""

    assert [%ToolCall{name: "GenerateUsername", args: %{"name" => "Sally"}}] =
             assistant_tool_call.tool_calls

    assert [
             %InvalidToolCall{
               id: "call_bad",
               type: :invalid_tool_call,
               name: "GenerateUsername",
               args: "oops"
             }
           ] = assistant_tool_call.metadata[:invalid_tool_calls]

    assert {:ok, openai_messages} =
             ChatMessages.to_openai_messages([
               MessageLike.to_message(%{"role" => "user", "content" => "foo", "name" => "test"})
               |> elem(1),
               developer_message,
               function_message,
               Message.tool("foo", tool_call_id: "bar"),
               assistant_tool_call
             ])

    assert %{"role" => "user", "content" => "foo", "name" => "test"} in openai_messages
    assert %{"role" => "developer", "content" => "dev"} in openai_messages

    assert %{
             "role" => "assistant",
             "content" => ~s({"result":"Example #1"}),
             "name" => "test_function"
           } in openai_messages

    assert %{"role" => "tool", "content" => "foo", "tool_call_id" => "bar"} in openai_messages

    assert Enum.any?(openai_messages, fn
             %{"role" => "assistant", "content" => "", "tool_calls" => calls} ->
               Enum.any?(
                 calls,
                 &(&1["id"] == "call_wm0" and
                     &1["function"]["name"] == "GenerateUsername" and
                     &1["function"]["arguments"] == BeamWeaver.JSON.encode!(%{"name" => "Sally"}))
               ) and
                 Enum.any?(
                   calls,
                   &(&1["id"] == "call_bad" and &1["function"]["arguments"] == "oops")
                 )

             _other ->
               false
           end)
  end

  test "Responses API encoder preserves developer role metadata" do
    assert {:ok, [%{"role" => "developer"}]} =
             Messages.to_responses_input([
               Message.system("dev instructions", metadata: %{openai_role: :developer})
             ])
  end

  test "returns provider response errors instead of building empty assistant messages" do
    assert {:error, error} =
             Messages.response_to_message(%{
               "id" => "resp_123",
               "error" => %{"message" => "Test error", "code" => "server_error"}
             })

    assert error.type == :response_error
    assert error.message == "Test error"
    assert error.details.error["code"] == "server_error"
  end
end
