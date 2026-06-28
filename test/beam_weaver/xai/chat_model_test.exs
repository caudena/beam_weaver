defmodule BeamWeaver.XAI.ChatModelTest do
  use ExUnit.Case

  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.EmbeddingModel, as: CoreEmbeddingModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.XAI.ChatCompletionsModel
  alias BeamWeaver.XAI.ChatModel
  alias BeamWeaver.XAI.Client
  alias BeamWeaver.XAI.EmbeddingModel
  alias BeamWeaver.XAI.Error
  alias BeamWeaver.XAI.Messages
  alias BeamWeaver.XAI.Tools

  test "namespace and client constructors read xAI config defaults and derive endpoints" do
    with_config(
      :xai,
      [
        api_key: "env-secret",
        base_url: "https://proxy.test/v1"
      ],
      fn ->
        model = BeamWeaver.XAI.chat_model(default_headers: [{"user-agent", "beam-weaver-test"}])
        request = Client.request(%Client{endpoint: model.endpoint, api_key: model.api_key}, %{})

        assert model.endpoint == "https://proxy.test/v1/responses"
        assert model.api_key == "env-secret"
        assert {"authorization", "Bearer env-secret"} in request.headers

        chat_model = BeamWeaver.XAI.chat_completions_model()
        assert chat_model.endpoint == "https://proxy.test/v1/chat/completions"
      end
    )
  end

  test "ChatCompletionsModel.new/1 accepts the streaming flag without crashing" do
    # :streaming is a validation-only flag; it must not reach struct!/2 (no such field).
    assert %ChatCompletionsModel{} = ChatCompletionsModel.new(streaming: true)
    assert %ChatCompletionsModel{} = ChatCompletionsModel.new(streaming: true, n: 1)

    assert_raise ArgumentError, "n must be 1 when streaming", fn ->
      ChatCompletionsModel.new(streaming: true, n: 2)
    end
  end

  test "model constructors accept xAI base_url alias" do
    responses = ChatModel.new(base_url: "https://proxy.test/v1")
    chat_completions = ChatCompletionsModel.new(base_url: "https://proxy.test/v1")

    assert responses.endpoint == "https://proxy.test/v1/responses"
    assert chat_completions.endpoint == "https://proxy.test/v1/chat/completions"
  end

  test "client supports per-call headers and x-grok conversation routing" do
    client = Client.new(api_key: "xai-secret", x_grok_conv_id: "model-conv")

    model_request = Client.request(client, %{})
    assert {"x-grok-conv-id", "model-conv"} in model_request.headers

    call_request =
      Client.request(client, %{},
        x_grok_conv_id: "call-conv",
        headers: [{"x-custom-cache", "enabled"}]
      )

    assert {"x-grok-conv-id", "call-conv"} in call_request.headers
    refute {"x-grok-conv-id", "model-conv"} in call_request.headers
    assert {"x-custom-cache", "enabled"} in call_request.headers
  end

  test "invokes xAI Responses API through fake transport" do
    model =
      ChatModel.new(
        model: "grok-4.3",
        api_key: "xai-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          expect: %{
            method: :post,
            path: "/v1/responses",
            json: %{
              "model" => "grok-4.3",
              "input" => [%{"type" => "message", "role" => "user", "content" => "ping"}],
              "stream" => false
            }
          },
          body: %{
            "id" => "resp_xai",
            "model" => "grok-4.3",
            "status" => "completed",
            "output" => [
              %{
                "id" => "msg_1",
                "type" => "message",
                "role" => "assistant",
                "content" => [%{"type" => "output_text", "text" => "pong"}]
              }
            ],
            "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
          }
        ]
      )

    assert {:ok, response} = CoreChatModel.invoke(model, [Message.user("ping")])
    assert Message.text(response) == "pong"
    assert response.metadata.model_provider == "xai"
    assert response.usage_metadata == %{input_tokens: 2, output_tokens: 3, total_tokens: 5}

    assert_received {:fake_transport_request, request}
    assert {"authorization", "Bearer xai-secret"} in request.headers
  end

  test "tool helpers cover xAI Responses and Chat Completions built-ins" do
    assert Tools.code_execution() == %{"type" => "code_execution"}

    assert Tools.file_search(collection_ids: ["col_1"]) == %{
             "type" => "file_search",
             "collection_ids" => ["col_1"]
           }

    assert Tools.attachment_search() == %{"type" => "attachment_search"}
    assert Tools.shell() == %{"type" => "shell"}
    assert Tools.view_image() == %{"type" => "view_image"}
    assert Tools.view_x_video() == %{"type" => "view_x_video"}

    assert Tools.to_chat_completions_tools([Tools.live_search(search_depth: :deep)]) == [
             %{"type" => "live_search", "search_depth" => "deep"}
           ]
  end

  test "Responses request body supports tools, structured output, reasoning, and search controls" do
    assert {:ok, body} =
             ChatModel.request_body(
               ChatModel.new(model: "grok-4.3", max_turns: 2, prompt_cache_key: "model-cache"),
               [Message.user("search")],
               tools: [Tools.web_search()],
               search_parameters: %{mode: :auto},
               response_format: %{
                 name: "Answer",
                 schema: %{type: :object, properties: %{answer: %{type: :string}}}
               },
               reasoning: %{effort: :high}
             )

    assert body["model"] == "grok-4.3"
    assert body["tools"] == [%{"type" => "web_search"}]
    assert body["text"]["format"]["type"] == "json_schema"
    assert body["reasoning"] == %{"effort" => "high"}
    assert body["max_turns"] == 2
    assert body["prompt_cache_key"] == "model-cache"
    assert body["search_parameters"] == %{"mode" => "auto"}
    refute Map.has_key?(body, "deferred")

    assert {:ok, per_call_body} =
             ChatModel.request_body(
               ChatModel.new(model: "grok-4.3", prompt_cache_key: "model-cache"),
               [Message.user("search")],
               prompt_cache_key: "call-cache"
             )

    assert per_call_body["prompt_cache_key"] == "call-cache"
  end

  test "xAI reasoning profiles omit unsupported stop while non-reasoning chat models preserve it" do
    assert {:ok, responses_body} =
             ChatModel.request_body(
               ChatModel.new(model: "grok-4.3"),
               [Message.user("stop check")],
               stop: ["END"]
             )

    refute Map.has_key?(responses_body, "stop")

    assert {:ok, reasoning_chat_body} =
             ChatCompletionsModel.request_body(
               ChatCompletionsModel.new(model: "grok-4.20-0309-reasoning"),
               [Message.user("stop check")],
               stop: ["END"]
             )

    refute Map.has_key?(reasoning_chat_body, "stop")

    assert {:ok, non_reasoning_chat_body} =
             ChatCompletionsModel.request_body(
               ChatCompletionsModel.new(model: "grok-4.20-0309-non-reasoning"),
               [Message.user("stop check")],
               stop: ["END"]
             )

    assert non_reasoning_chat_body["stop"] == ["END"]
  end

  test "Responses request body rejects deferred mode before transport" do
    assert {:error, error} =
             ChatModel.request_body(
               ChatModel.new(model: "grok-4.3"),
               [Message.user("search")],
               deferred: true
             )

    assert error.type == :unsupported_model_param
    assert :deferred in error.details.params
  end

  test "Responses request body rejects Chat Completions-only live search tools" do
    assert {:error, error} =
             ChatModel.request_body(
               ChatModel.new(model: "grok-4.3"),
               [Message.user("search")],
               tools: [Tools.live_search()]
             )

    assert error.type == :unsupported_feature
    assert error.details.api == :responses
    assert error.details.unsupported == ["live_search"]
  end

  test "Chat Completions request body preserves xAI built-ins and deferred mode" do
    assert {:ok, body} =
             ChatCompletionsModel.request_body(
               ChatCompletionsModel.new(model: "grok-4.3"),
               [Message.user("search")],
               tools: [Tools.live_search(search_depth: :deep)],
               model_kwargs: %{custom_param: true},
               deferred: true,
               search_parameters: %{mode: :auto},
               stream: true
             )

    assert body["model"] == "grok-4.3"
    assert body["messages"] == [%{"role" => "user", "content" => "search"}]
    assert body["tools"] == [%{"type" => "live_search", "search_depth" => "deep"}]
    assert body["custom_param"] == true
    assert body["deferred"] == true
    assert body["search_parameters"] == %{"mode" => "auto"}
    assert body["stream_options"] == %{"include_usage" => true}
  end

  test "Chat Completions request body rejects Responses-only server tools" do
    assert {:error, error} =
             ChatCompletionsModel.request_body(
               ChatCompletionsModel.new(model: "grok-4.3"),
               [Message.user("search")],
               tools: [Tools.web_search()]
             )

    assert error.type == :unsupported_feature
    assert error.details.api == :chat_completions
    assert error.details.unsupported == ["web_search"]
  end

  test "Chat Completions validates xAI n and streaming constructor constraints" do
    assert_raise ArgumentError, "n must be at least 1", fn ->
      ChatCompletionsModel.new(n: 0)
    end

    assert_raise ArgumentError, "n must be 1 when streaming", fn ->
      ChatCompletionsModel.new(n: 2, streaming: true)
    end
  end

  test "Chat Completions response preserves reasoning, citations, provider, and xAI usage accounting" do
    response = %{
      "id" => "chatcmpl_xai",
      "model" => "grok-4.3",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => "27",
            "reasoning_content" => "I counted."
          },
          "finish_reason" => "stop"
        }
      ],
      "citations" => ["https://docs.x.ai"],
      "usage" => %{
        "prompt_tokens" => 1,
        "completion_tokens" => 2,
        "total_tokens" => 3,
        "completion_tokens_details" => %{"reasoning_tokens" => 4}
      }
    }

    assert {:ok, message} = Messages.chat_completions_to_message(response)
    assert Message.text(message) == "27"
    assert message.metadata.model_provider == "xai"
    assert message.metadata.reasoning_content == "I counted."
    assert message.metadata.citations == ["https://docs.x.ai"]
    assert message.usage_metadata.output_tokens == 6
    assert message.usage_metadata.total_tokens == 7
  end

  test "Chat Completions stream_response reconstructs assistant messages" do
    body = """
    data: {"id":"chatcmpl_xai","model":"grok-4.3","choices":[{"index":0,"delta":{"content":"po"},"finish_reason":null}]}

    data: {"id":"chatcmpl_xai","model":"grok-4.3","choices":[{"index":0,"delta":{"content":"ng"},"finish_reason":null}]}

    data: {"id":"chatcmpl_xai","model":"grok-4.3","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}

    data: [DONE]
    """

    model =
      ChatCompletionsModel.new(
        model: "grok-4.3",
        api_key: "xai-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{
            method: :post,
            path: "/v1/chat/completions",
            json: %{
              "model" => "grok-4.3",
              "messages" => [%{"role" => "user", "content" => "stream"}],
              "stream" => true,
              "stream_options" => %{"include_usage" => true}
            }
          },
          headers: [{"content-type", "text/event-stream"}],
          body: body
        ]
      )

    assert {:ok, response} = ChatCompletionsModel.stream_response(model, [Message.user("stream")])
    assert Message.text(response) == "pong"
    assert response.metadata.model_provider == "xai"
  end

  test "xAI Chat Completions stream_response reconstructs streamed tool-call chunks" do
    body = """
    data: {"id":"chatcmpl_xai_tools","model":"grok-4.3","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

    data: {"id":"chatcmpl_xai_tools","model":"grok-4.3","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_weather","function":{"name":"weather","arguments":"{\\"city\\""}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl_xai_tools","model":"grok-4.3","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"Nicosia\\"}"}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl_xai_tools","model":"grok-4.3","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}

    data: [DONE]
    """

    model =
      ChatCompletionsModel.new(
        model: "grok-4.3",
        api_key: "xai-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/v1/chat/completions"},
          headers: [{"content-type", "text/event-stream"}],
          body: body
        ]
      )

    assert {:ok, response} = ChatCompletionsModel.stream_response(model, [Message.user("tools")])

    assert response.status == "tool_calls"
    assert response.metadata.model_provider == "xai"
    assert [%{id: "call_weather", name: "weather", args: %{"city" => "Nicosia"}}] = response.tool_calls
  end

  test "Chat Completions stream decoder reads atom-key message metadata" do
    body = """
    data: {"id":"chatcmpl_xai_decoder","model":"grok-4.3","service_tier":"default","system_fingerprint":"fp_xai","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}

    data: {"id":"chatcmpl_xai_decoder","model":"grok-4.3","service_tier":"default","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}

    data: [DONE]
    """

    response = %BeamWeaver.Transport.Response{status: 200, body: body, headers: []}

    assert {:ok, decoded} =
             BeamWeaver.XAI.Client.ResponseDecoder.chat_completions_stream_response(
               {:ok, response},
               []
             )

    assert decoded["id"] == "chatcmpl_xai_decoder"
    assert decoded["model"] == "grok-4.3"
    assert decoded["system_fingerprint"] == "fp_xai"
    assert decoded["service_tier"] == "default"
    assert decoded["usage"]["completion_tokens"] == 2
  end

  test "stream_events returns envelopes tagged with xAI invocation metadata" do
    body = """
    data: {"id":"chatcmpl_xai","model":"grok-4.3","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}

    data: {"id":"chatcmpl_xai","model":"grok-4.3","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}

    data: [DONE]
    """

    model =
      ChatCompletionsModel.new(
        model: "grok-4.3",
        api_key: "xai-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/v1/chat/completions"},
          headers: [{"content-type", "text/event-stream"}],
          body: body
        ]
      )

    assert {:ok, stream} = CoreChatModel.stream_events(model, [Message.user("events")])
    events = Enum.to_list(stream)

    assert Enum.any?(events, &match?(%{event: %Events.Token{text: "ok"}}, &1))
    assert Enum.all?(events, &(&1.metadata.provider == :xai))
    assert Enum.all?(events, &(&1.metadata.model_provider == :xai))
  end

  test "deferred completion returns pending tuple for HTTP 202" do
    client =
      Client.new(
        api_key: "xai-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          expect: %{method: :get, path: "/v1/chat/deferred-completion/req_123"},
          status: 202,
          body: %{"id" => "req_123", "status" => "pending"}
        ]
      )

    assert {:ok, {:pending, %{"status" => "pending"}}} =
             Client.deferred_completion(client, "req_123")

    assert_received {:fake_transport_request, request}
    assert {"authorization", "Bearer xai-secret"} in request.headers
  end

  test "xAI context_length_exceeded HTTP errors are normalized as context overflow" do
    model =
      ChatModel.new(
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/v1/responses"},
          status: 400,
          body: %{
            "error" => %{
              "code" => "context_length_exceeded",
              "message" => "input tokens exceed the model context length"
            }
          }
        ]
      )

    assert {:error, %Error{type: :context_overflow} = error} =
             CoreChatModel.invoke(model, [Message.user("test")])

    assert error.details.status == 400
    assert error.details.code == "context_length_exceeded"
    assert error.message =~ "input tokens exceed"
  end

  test "embeds through xAI embeddings endpoint" do
    model =
      EmbeddingModel.new(
        api_key: "xai-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          expect: %{
            method: :post,
            path: "/v1/embeddings",
            json: %{
              "model" => "v1",
              "input" => "alpha",
              "encoding_format" => "float",
              "preview" => true
            }
          },
          body: %{
            "object" => "list",
            "model" => "v1",
            "data" => [
              %{"index" => 0, "embedding" => [0.1, 0.2], "object" => "embedding"}
            ],
            "usage" => %{"prompt_tokens" => 1, "total_tokens" => 1}
          }
        ]
      )

    assert {:ok, [0.1, 0.2]} =
             CoreEmbeddingModel.embed_query(model, "alpha",
               encoding_format: :float,
               preview: true
             )

    assert_received {:fake_transport_request, request}
    assert {"authorization", "Bearer xai-secret"} in request.headers
  end

  test "model initializer supports current xAI identifiers, aliases, deprecations, and embeddings" do
    assert {:ok, explicit} = Models.init_chat_model("xai:grok-4.3")
    assert explicit.__struct__ == ChatModel
    assert explicit.profile.provider == :xai

    assert {:ok, alias_model} = Models.init_chat_model("xai:grok-4")
    assert alias_model.profile.extra.canonical_model == "grok-4.3"

    assert {:error, deprecated} = Models.init_chat_model("grok-4-fast-reasoning")
    assert deprecated.type == :deprecated_model
    assert deprecated.details.replacement == "grok-4.3"
    assert deprecated.details.reasoning_effort == "low"

    assert {:ok, chat_completions} =
             Models.init_chat_model("xai:grok-4", api: :chat_completions)

    assert chat_completions.__struct__ == ChatCompletionsModel

    assert {:ok, embeddings} = Models.init_embeddings("xai:v1")
    assert embeddings.__struct__ == EmbeddingModel
  end

  test "structured output leaves dynamic empty object maps open for xAI" do
    format =
      BeamWeaver.XAI.Messages.structured_output_format(
        "crm_updates",
        %{
          "type" => "object",
          "properties" => %{
            "contacts_to_update" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "contact_id" => %{"type" => "integer"},
                  "properties" => %{"type" => "object"}
                },
                "required" => ["properties"]
              }
            }
          },
          "required" => ["contacts_to_update"]
        },
        strict: true
      )

    dynamic_properties =
      get_in(format, [
        "schema",
        "properties",
        "contacts_to_update",
        "items",
        "properties",
        "properties"
      ])

    assert dynamic_properties == %{"type" => "object"}
    refute Map.has_key?(dynamic_properties, "additionalProperties")

    contact_update =
      get_in(format, ["schema", "properties", "contacts_to_update", "items"])

    assert contact_update["additionalProperties"] == false
    assert Enum.sort(contact_update["required"]) == ["contact_id", "properties"]
  end

  test "Responses request body opens dynamic object maps inside nullable branches" do
    assert {:ok, body} =
             ChatModel.request_body(
               ChatModel.new(model: "grok-4.3"),
               [Message.user("update crm")],
               response_format: %{name: "crm_updates", schema: nullable_crm_schema()}
             )

    dynamic_properties =
      get_in(body, [
        "text",
        "format",
        "schema",
        "properties",
        "contacts_to_update",
        "anyOf",
        Access.at(0),
        "items",
        "properties",
        "properties"
      ])

    assert dynamic_properties == %{"type" => "object"}
    refute Map.has_key?(dynamic_properties, "additionalProperties")

    contact_update =
      get_in(body, [
        "text",
        "format",
        "schema",
        "properties",
        "contacts_to_update",
        "anyOf",
        Access.at(0),
        "items"
      ])

    assert contact_update["additionalProperties"] == false
  end

  test "Chat Completions request body opens dynamic object maps inside json_schema format" do
    assert {:ok, body} =
             ChatCompletionsModel.request_body(
               ChatCompletionsModel.new(model: "grok-4.3"),
               [Message.user("update crm")],
               response_format: %{name: "crm_updates", schema: nullable_crm_schema()}
             )

    dynamic_properties =
      get_in(body, [
        "response_format",
        "json_schema",
        "schema",
        "properties",
        "contacts_to_update",
        "anyOf",
        Access.at(0),
        "items",
        "properties",
        "properties"
      ])

    assert dynamic_properties == %{"type" => "object"}
    refute Map.has_key?(dynamic_properties, "additionalProperties")
  end

  defp with_config(group, values, fun) do
    BeamWeaver.TestSupport.ConfigHelper.put_config(group, values)
    fun.()
  end

  defp nullable_crm_schema do
    %{
      "type" => "object",
      "properties" => %{
        "contacts_to_update" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "contact_id" => %{"type" => "integer"},
              "properties" => %{"type" => "object"}
            },
            "required" => ["properties"]
          }
        }
      },
      "required" => []
    }
  end
end
