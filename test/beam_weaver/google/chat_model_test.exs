defmodule BeamWeaver.Google.ChatModelTest do
  use ExUnit.Case

  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message
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
