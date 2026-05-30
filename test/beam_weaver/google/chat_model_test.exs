defmodule BeamWeaver.Google.ChatModelTest do
  use ExUnit.Case

  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Google.ChatModel
  alias BeamWeaver.Google.Client
  alias BeamWeaver.Google.Tools
  alias BeamWeaver.Models
  alias BeamWeaver.Provider.Compatibility
  alias BeamWeaver.Provider.DecodeMessage
  alias BeamWeaver.Provider.EncodeMessage

  test "namespace and client constructors read Google config defaults and derive endpoints" do
    with_config(
      :google,
      [
        api_key: "env-secret",
        base_url: "https://generativelanguage.googleapis.test/v1beta"
      ],
      fn ->
        model = BeamWeaver.Google.chat_model(default_headers: [{"x-test", "yes"}])
        client = Client.new(base_url: model.base_url, api_key: model.api_key)
        request = Client.request(client, model.model, :generate_content, %{}, [])

        assert model.model == "gemini-3.5-flash"
        assert model.api_key == "env-secret"

        assert request.url ==
                 "https://generativelanguage.googleapis.test/v1beta/models/gemini-3.5-flash:generateContent"

        assert {"x-goog-api-key", "env-secret"} in request.headers
      end
    )
  end

  test "request body supports system messages, tools, structured output, thinking, and safety" do
    tool =
      Tool.from_function!(
        name: "lookup",
        description: "Lookup a record",
        input_schema: %{type: :object, properties: %{id: %{type: :string}}},
        handler: fn _input, _opts -> :ok end
      )

    assert {:ok, body} =
             ChatModel.request_body(
               %ChatModel{
                 model: "gemini-3.5-flash",
                 temperature: 0.2,
                 thinking_budget: 128,
                 include_thoughts: true
               },
               [Message.system("follow policy"), Message.user("ping")],
               tools: [Tools.google_search(), tool],
               tool_choice: "lookup",
               response_format: %{
                 schema: %{type: :object, properties: %{answer: %{type: :string}}}
               },
               safety_settings: %{HARM_CATEGORY_DANGEROUS_CONTENT: :BLOCK_ONLY_HIGH}
             )

    assert body["systemInstruction"] == %{"parts" => [%{"text" => "follow policy"}]}
    assert body["contents"] == [%{"role" => "user", "parts" => [%{"text" => "ping"}]}]
    assert body["generationConfig"]["temperature"] == 0.2

    assert body["generationConfig"]["thinkingConfig"] == %{
             "thinkingBudget" => 128,
             "includeThoughts" => true
           }

    assert body["generationConfig"]["responseMimeType"] == "application/json"
    assert body["generationConfig"]["responseJsonSchema"]["type"] == "object"
    assert %{"googleSearch" => %{}} in body["tools"]
    assert [%{"functionDeclarations" => [declaration]}] = Enum.drop(body["tools"], 1)
    assert declaration["name"] == "lookup"

    assert body["toolConfig"]["functionCallingConfig"] == %{
             "mode" => "ANY",
             "allowedFunctionNames" => ["lookup"]
           }

    assert body["safetySettings"] == [
             %{
               "category" => "HARM_CATEGORY_DANGEROUS_CONTENT",
               "threshold" => "BLOCK_ONLY_HIGH"
             }
           ]
  end

  test "request body removes unsupported JSON Schema keywords from function declarations" do
    tool =
      Tool.from_function!(
        name: "lookup",
        description: "Lookup a record",
        input_schema: %{
          "title" => "lookup_input",
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "status" => %{"$ref" => "#/$defs/Status"},
            "filters" => %{
              "title" => "filters",
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{
                "query" => %{"title" => "query", "type" => "string"},
                "tags" => %{
                  "type" => "array",
                  "items" => %{
                    "title" => "tag",
                    "type" => "string"
                  }
                }
              },
              "required" => ["query"]
            }
          },
          "required" => ["status", "filters"],
          "$defs" => %{
            "Status" => %{
              "title" => "status",
              "type" => "string",
              "enum" => ["open", "closed"],
              "default" => "open"
            }
          }
        },
        handler: fn _input, _opts -> :ok end
      )

    assert {:ok, body} =
             ChatModel.request_body(
               %ChatModel{model: "gemini-3.5-flash"},
               [Message.user("ping")],
               tools: [tool]
             )

    assert [%{"functionDeclarations" => [declaration]}] = body["tools"]
    parameters = declaration["parameters"]
    filters = parameters["properties"]["filters"]
    status = parameters["properties"]["status"]
    query = filters["properties"]["query"]
    tag = filters["properties"]["tags"]["items"]

    assert parameters["type"] == "object"
    assert status == %{"type" => "string", "enum" => ["open", "closed"]}
    assert filters["type"] == "object"
    assert query["type"] == "string"
    assert tag["type"] == "string"
    assert parameters["required"] == ["status", "filters"]
    assert filters["required"] == ["query"]

    refute Map.has_key?(parameters, "$defs")
    refute Map.has_key?(parameters, "title")
    refute Map.has_key?(parameters, "additionalProperties")
    refute Map.has_key?(status, "title")
    refute Map.has_key?(status, "default")
    refute Map.has_key?(status, "$ref")
    refute Map.has_key?(filters, "title")
    refute Map.has_key?(filters, "additionalProperties")
    refute Map.has_key?(query, "title")
    refute Map.has_key?(tag, "title")
  end

  test "request body ignores internal tracing metadata for Google param validation" do
    assert {:ok, body} =
             ChatModel.request_body(
               %ChatModel{model: "gemini-3.5-flash"},
               [Message.user("ping")],
               metadata: %{lc_source: "compact_conversation"}
             )

    assert body["contents"] == [%{"role" => "user", "parts" => [%{"text" => "ping"}]}]
    refute Map.has_key?(body, "metadata")
  end

  test "request body keeps conversation summaries in contents before replayed tool calls" do
    call = %ToolCall{
      id: "call-1",
      name: "lookup",
      args: %{"q" => "beam"},
      thought_signature: "sig-a"
    }

    assert {:ok, body} =
             ChatModel.request_body(
               %ChatModel{model: "gemini-3.5-flash"},
               [
                 Message.system("follow policy"),
                 Message.system("Conversation summary:\nprevious context",
                   metadata: %{conversation_history_path: "/conversation_history/summary.md"}
                 ),
                 Message.assistant("", tool_calls: [call]),
                 Message.tool("found", tool_call_id: "call-1", name: "lookup")
               ]
             )

    assert body["systemInstruction"] == %{"parts" => [%{"text" => "follow policy"}]}

    assert body["contents"] == [
             %{"role" => "user", "parts" => [%{"text" => "Conversation summary:\nprevious context"}]},
             %{
               "role" => "model",
               "parts" => [
                 %{
                   "functionCall" => %{"name" => "lookup", "args" => %{"q" => "beam"}},
                   "thoughtSignature" => "sig-a"
                 }
               ]
             },
             %{
               "role" => "user",
               "parts" => [
                 %{
                   "functionResponse" => %{
                     "name" => "lookup",
                     "response" => %{"content" => "found"}
                   }
                 }
               ]
             }
           ]
  end

  test "request body encodes assistant tool-call history as Gemini function calls" do
    call = %ToolCall{
      id: "call-1",
      name: "lookup",
      args: %{"q" => "beam"},
      thought_signature: "sig-a"
    }

    assert {:ok, body} =
             ChatModel.request_body(
               %ChatModel{model: "gemini-3.5-flash"},
               [
                 Message.user("ping"),
                 Message.assistant(
                   [
                     %{
                       type: :tool_call,
                       id: "call-1",
                       name: "lookup",
                       args: %{"q" => "beam"},
                       thought_signature: "sig-a"
                     }
                   ],
                   tool_calls: [call]
                 )
               ]
             )

    assert body["contents"] == [
             %{"role" => "user", "parts" => [%{"text" => "ping"}]},
             %{
               "role" => "model",
               "parts" => [
                 %{
                   "functionCall" => %{"name" => "lookup", "args" => %{"q" => "beam"}},
                   "thoughtSignature" => "sig-a"
                 }
               ]
             }
           ]
  end

  test "request body preserves thought signatures from restored content metadata" do
    message =
      Message.assistant([
        %{
          "type" => "reasoning",
          "reasoning" => "thinking",
          "metadata" => %{"thoughtSignature" => "sig-reasoning"}
        },
        %{
          "type" => "tool_call",
          "id" => "call-1",
          "name" => "lookup",
          "args" => %{"q" => "beam"},
          "metadata" => %{"thoughtSignature" => "sig-call"}
        }
      ])

    assert {:ok, body} =
             ChatModel.request_body(
               %ChatModel{model: "gemini-3.5-flash"},
               [Message.user("ping"), message]
             )

    assert body["contents"] == [
             %{"role" => "user", "parts" => [%{"text" => "ping"}]},
             %{
               "role" => "model",
               "parts" => [
                 %{
                   "thought" => true,
                   "text" => "thinking",
                   "thoughtSignature" => "sig-reasoning"
                 },
                 %{
                   "functionCall" => %{"name" => "lookup", "args" => %{"q" => "beam"}},
                   "thoughtSignature" => "sig-call"
                 }
               ]
             }
           ]
  end

  test "decoded Gemini function calls preserve thought signatures for replay" do
    assert {:ok, decoded} =
             DecodeMessage.decode(
               %{
                 "candidates" => [
                   %{
                     "content" => %{
                       "role" => "model",
                       "parts" => [
                         %{
                           "functionCall" => %{"name" => "lookup", "args" => %{"q" => "beam"}},
                           "thoughtSignature" => "sig-a"
                         }
                       ]
                     }
                   }
                 ]
               },
               provider: :google
             )

    assert [%{type: :tool_call, name: "lookup", thought_signature: "sig-a"}] = decoded.content
    assert [%ToolCall{name: "lookup", thought_signature: "sig-a"}] = decoded.tool_calls
  end

  test "request body covers Gemini OpenAPI generation and tool config fields" do
    assert {:ok, body} =
             ChatModel.request_body(
               %ChatModel{model: "gemini-3.5-flash"},
               [Message.user("ping")],
               candidate_count: 2,
               frequency_penalty: 0.1,
               presence_penalty: 0.2,
               logprobs: 4,
               response_logprobs: true,
               response_format_config: %{"type" => "json"},
               response_modalities: ["TEXT"],
               media_resolution: "MEDIA_RESOLUTION_MEDIUM",
               seed: 42,
               speech_config: %{
                 "voiceConfig" => %{
                   "prebuiltVoiceConfig" => %{"voiceName" => "Kore"}
                 }
               },
               generation_config: %{"futureGenerationField" => "preserved"},
               tools: [
                 Tools.file_search(["fileSearchStores/store_123"]),
                 Tools.google_maps(),
                 Tools.mcp_servers([%{name: "servers/context"}])
               ],
               tool_choice: :auto,
               include_server_side_tool_invocations: true,
               retrieval_config: %{"latLng" => %{"latitude" => 1.0, "longitude" => 2.0}},
               service_tier: "PRIORITY",
               store: true
             )

    assert body["serviceTier"] == "PRIORITY"
    assert body["store"] == true

    assert body["generationConfig"] == %{
             "candidateCount" => 2,
             "frequencyPenalty" => 0.1,
             "presencePenalty" => 0.2,
             "logprobs" => 4,
             "responseLogprobs" => true,
             "responseFormat" => %{"type" => "json"},
             "responseModalities" => ["TEXT"],
             "mediaResolution" => "MEDIA_RESOLUTION_MEDIUM",
             "seed" => 42,
             "speechConfig" => %{
               "voiceConfig" => %{
                 "prebuiltVoiceConfig" => %{"voiceName" => "Kore"}
               }
             },
             "futureGenerationField" => "preserved"
           }

    assert %{"fileSearch" => %{"fileSearchStoreNames" => ["fileSearchStores/store_123"]}} in body[
             "tools"
           ]

    assert %{"googleMaps" => %{}} in body["tools"]
    assert %{"mcpServers" => [%{"name" => "servers/context"}]} in body["tools"]

    assert body["toolConfig"] == %{
             "functionCallingConfig" => %{"mode" => "AUTO"},
             "includeServerSideToolInvocations" => true,
             "retrievalConfig" => %{"latLng" => %{"latitude" => 1.0, "longitude" => 2.0}}
           }
  end

  test "invokes Gemini Developer API through fake transport and normalizes metadata" do
    model =
      ChatModel.new(
        model: "gemini-3.5-flash",
        api_key: "google-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          headers: [{"x-request-id", "req_google"}],
          expect: %{
            method: :post,
            path: "/models/gemini-3.5-flash:generateContent",
            json: %{
              "contents" => [%{"role" => "user", "parts" => [%{"text" => "ping"}]}]
            }
          },
          body: %{
            "responseId" => "resp_google",
            "modelVersion" => "gemini-3.5-flash",
            "modelStatus" => %{"status" => "STABLE"},
            "candidates" => [
              %{
                "index" => 0,
                "finishReason" => "STOP",
                "finishMessage" => "complete",
                "content" => %{
                  "role" => "model",
                  "parts" => [%{"text" => "pong"}]
                },
                "tokenCount" => 4,
                "avgLogprobs" => -0.01,
                "logprobsResult" => %{"topCandidates" => []},
                "safetyRatings" => [%{"category" => "HARM_CATEGORY_TEST", "probability" => "LOW"}],
                "citationMetadata" => %{"citationSources" => [%{"startIndex" => 0}]},
                "groundingMetadata" => %{"webSearchQueries" => ["beam weaver"]},
                "urlContextMetadata" => %{
                  "urlMetadata" => [%{"retrievedUrl" => "https://example.test"}]
                }
              }
            ],
            "usageMetadata" => %{
              "promptTokenCount" => 2,
              "promptTokensDetails" => [%{"modality" => "TEXT", "tokenCount" => 2}],
              "candidatesTokenCount" => 3,
              "candidatesTokensDetails" => [%{"modality" => "TEXT", "tokenCount" => 3}],
              "thoughtsTokenCount" => 1,
              "cachedContentTokenCount" => 1,
              "cacheTokensDetails" => [%{"modality" => "TEXT", "tokenCount" => 1}],
              "toolUsePromptTokenCount" => 2,
              "toolUsePromptTokensDetails" => [%{"modality" => "TEXT", "tokenCount" => 2}],
              "totalTokenCount" => 6,
              "serviceTier" => "PRIORITY"
            }
          }
        ]
      )

    assert {:ok, response} = CoreChatModel.invoke(model, [Message.user("ping")])
    assert Message.text(response) == "pong"

    assert response.usage_metadata == %{
             input_tokens: 2,
             output_tokens: 4,
             total_tokens: 6,
             input_token_details: %{
               cache_read: 1,
               prompt_tokens_details: [%{"modality" => "TEXT", "tokenCount" => 2}],
               cache_tokens_details: [%{"modality" => "TEXT", "tokenCount" => 1}],
               tool_use_prompt: 2,
               tool_use_prompt_tokens_details: [%{"modality" => "TEXT", "tokenCount" => 2}]
             },
             output_token_details: %{
               reasoning: 1,
               candidates_tokens_details: [%{"modality" => "TEXT", "tokenCount" => 3}]
             },
             service_tier: "PRIORITY"
           }

    assert response.response_metadata.model.provider == :google
    assert response.response_metadata.usage.reasoning_tokens == 1
    assert response.response_metadata.usage.service_tier == "PRIORITY"
    assert response.response_metadata.usage.input_token_details.tool_use_prompt == 2
    assert response.response_metadata.safety.finish_reason == "STOP"
    assert response.response_metadata.finish_message == "complete"
    assert response.response_metadata.model_status == %{"status" => "STABLE"}
    assert response.response_metadata.candidate_token_count == 4
    assert response.response_metadata.avg_logprobs == -0.01

    assert response.response_metadata.citations == %{
             "citationSources" => [%{"startIndex" => 0}]
           }

    assert response.response_metadata.grounding.grounding_metadata["webSearchQueries"] == [
             "beam weaver"
           ]

    assert response.response_metadata.grounding.web_search_queries == ["beam weaver"]

    assert response.response_metadata.grounding.citations["citationSources"] == [
             %{"startIndex" => 0}
           ]

    assert response.response_metadata.transport.request_id == "resp_google"

    assert_received {:fake_transport_request, request}
    assert {"x-goog-api-key", "google-secret"} in request.headers
  end

  test "model initialization uses google: prefix and rejects bare Gemini aliases" do
    assert {:ok, model} = Models.init_chat_model("google:gemini-3.5-flash")
    assert %ChatModel{} = model
    assert model.profile.provider == :google
    assert Compatibility.supports?(model, :structured_output)

    assert {:error, error} = Models.init_chat_model("gemini-3.5-flash")
    assert error.type == :invalid_model
    assert error.details.expected == "google:gemini-3.5-flash"
  end

  test "gemini 3.5 flash profile matches published model capabilities" do
    assert {:ok, model} = Models.init_chat_model("google:gemini-3.5-flash")

    assert model.profile.provider == :google
    assert model.profile.max_input_tokens == 1_048_576
    assert model.profile.max_output_tokens == 65_536
    assert model.profile.text_outputs
    assert model.profile.reasoning_output
    assert model.profile.structured_output
    assert model.profile.extra.batch_api
    assert model.profile.extra.caching
    assert :file_search in model.profile.extra.built_in_tools
    assert :google_maps in model.profile.extra.built_in_tools
    refute :computer_use in model.profile.extra.built_in_tools
    refute Compatibility.supports?(model, :image_output)
    refute Compatibility.supports?(model, :audio_output)
    assert Compatibility.supports?(model, :thinking)
  end

  test "gemini 3.1 pro preview profile is the recommended Pro replacement" do
    assert {:ok, model} = Models.init_chat_model("google:gemini-3.1-pro-preview")

    assert model.profile.provider == :google
    assert model.profile.max_input_tokens == 1_048_576
    assert model.profile.max_output_tokens == 65_536
    assert model.profile.reasoning_output
    assert model.profile.structured_output
    assert model.profile.extra.batch_api
    assert model.profile.extra.file_search_scope == :ai_studio_only
    assert :file_search in model.profile.extra.built_in_tools
    refute Compatibility.supports?(model, :image_output)
    refute Compatibility.supports?(model, :audio_output)
  end

  test "unsupported Gemini 3.5 output modalities fail before transport by default" do
    assert {:ok, model} =
             Models.init_chat_model("google:gemini-3.5-flash",
               response_modalities: ["IMAGE"],
               transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
               transport_opts: [parent: self()]
             )

    assert {:error, error} = CoreChatModel.invoke(model, [Message.user("draw this")])
    assert error.type == :unsupported_feature
    assert error.details.provider == :google
    assert error.details.model == "gemini-3.5-flash"
    assert error.details.feature == :image_output

    refute_received {:fake_transport_request, _request}
  end

  test "provider message protocols route google through the native translator" do
    assert {:ok, encoded} = EncodeMessage.encode(Message.user("hello"), provider: :google)
    assert encoded == %{"role" => "user", "parts" => [%{"text" => "hello"}]}

    assert {:ok, decoded} =
             DecodeMessage.decode(
               %{
                 "candidates" => [
                   %{
                     "content" => %{"role" => "model", "parts" => [%{"text" => "hi"}]}
                   }
                 ]
               },
               provider: :google
             )

    assert Message.text(decoded) == "hi"
  end

  test "token counting uses Gemini countTokens endpoint" do
    model =
      ChatModel.new(
        model: "gemini-3.5-flash",
        api_key: "google-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{
            method: :post,
            path: "/models/gemini-3.5-flash:countTokens",
            json: %{
              "contents" => [%{"role" => "user", "parts" => [%{"text" => "count me"}]}],
              "generateContentRequest" => %{
                "contents" => [%{"role" => "user", "parts" => [%{"text" => "count me"}]}]
              }
            }
          },
          body: %{"totalTokens" => 4}
        ]
      )

    assert {:ok, 4} = ChatModel.count_tokens(model, "count me")
  end

  defp with_config(group, values, fun) do
    BeamWeaver.TestSupport.ConfigHelper.put_config(group, values)
    fun.()
  end
end
