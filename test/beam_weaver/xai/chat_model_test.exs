defmodule BeamWeaver.XAI.ChatModelTest do
  use ExUnit.Case

  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.XAI.ChatCompletionsModel
  alias BeamWeaver.XAI.ChatModel
  alias BeamWeaver.XAI.Client
  alias BeamWeaver.Core.Error
  alias BeamWeaver.XAI.Messages
  alias BeamWeaver.XAI.Tools

  test "namespace and client constructors read xAI config defaults and derive endpoints" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:xai, api_key: "env-secret", base_url: "https://proxy.test/v1")

    model = BeamWeaver.XAI.chat_model(default_headers: [{"user-agent", "beam-weaver-test"}])
    request = Client.request(%Client{endpoint: model.endpoint, api_key: model.api_key}, %{})

    assert model.endpoint == "https://proxy.test/v1/responses"
    assert model.api_key == "env-secret"
    assert {"authorization", "Bearer env-secret"} in request.headers

    chat_model = BeamWeaver.XAI.chat_completions_model()
    assert chat_model.endpoint == "https://proxy.test/v1/chat/completions"
  end

  test "ChatCompletionsModel.new/1 accepts the streaming flag without crashing" do
    assert %ChatCompletionsModel{} = ChatCompletionsModel.new(streaming: true)
    assert %ChatCompletionsModel{} = ChatCompletionsModel.new(streaming: true, n: 1)
  end

  test "model constructors accept xAI base_url alias" do
    responses = ChatModel.new(base_url: "https://proxy.test/v1")
    chat_completions = ChatCompletionsModel.new(base_url: "https://proxy.test/v1")

    assert responses.endpoint == "https://proxy.test/v1/responses"
    assert chat_completions.endpoint == "https://proxy.test/v1/chat/completions"
  end

  test "model constructors default to Grok 4.6 and send priority processing" do
    responses = ChatModel.new(service_tier: :priority)
    chat_completions = ChatCompletionsModel.new(service_tier: :priority)

    assert responses.model == "grok-4.6"
    assert chat_completions.model == "grok-4.6"
    assert BeamWeaver.XAI.Provider.default_model(:chat) == "grok-4.6"

    assert {:ok, responses_body} =
             ChatModel.request_body(responses, [Message.user("priority response")])

    assert responses_body["service_tier"] == "priority"

    assert {:ok, chat_completions_body} =
             ChatCompletionsModel.request_body(
               chat_completions,
               [Message.user("priority response")]
             )

    assert chat_completions_body["service_tier"] == "priority"
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
              "include" => ["reasoning.encrypted_content"],
              "stream" => false
            }
          },
          headers: [
            {"x-request-id", "req-xai"},
            {"x-metrics-ttft-ms", "42"},
            {"x-ratelimit-limit-requests", "3600"},
            {"x-ratelimit-remaining-requests", "3599"}
          ],
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
    assert response.response_metadata.headers.request_id == "req-xai"
    assert response.response_metadata.headers.x_metrics_ttft_ms == "42"
    assert response.response_metadata.headers.x_ratelimit_limit_requests == "3600"
    assert response.response_metadata.headers.x_ratelimit_remaining_requests == "3599"
    assert response.usage_metadata == %{input_tokens: 2, output_tokens: 3, total_tokens: 5}

    assert_received {:fake_transport_request, request}
    assert {"authorization", "Bearer xai-secret"} in request.headers
  end

  test "xAI Responses fake transport asserts prompt cache key and conversation header" do
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
              "input" => [%{"type" => "message", "role" => "user", "content" => "cache me"}],
              "include" => ["reasoning.encrypted_content"],
              "stream" => false,
              "prompt_cache_key" => "cache-run"
            }
          },
          body: %{
            "id" => "resp_xai_cache",
            "model" => "grok-4.3",
            "status" => "completed",
            "output" => [
              %{
                "id" => "msg_1",
                "type" => "message",
                "role" => "assistant",
                "content" => [%{"type" => "output_text", "text" => "cached"}]
              }
            ]
          }
        ]
      )

    assert {:ok, response} =
             CoreChatModel.invoke(model, [Message.user("cache me")],
               prompt_cache_key: "cache-run",
               x_grok_conv_id: "conv-run"
             )

    assert Message.text(response) == "cached"
    assert_received {:fake_transport_request, request}
    assert request.json["prompt_cache_key"] == "cache-run"
    assert {"x-grok-conv-id", "conv-run"} in request.headers
  end

  test "Responses request body supports tools, structured output, reasoning, and turn limits" do
    assert {:ok, body} =
             ChatModel.request_body(
               ChatModel.new(model: "grok-4.3", max_turns: 2, prompt_cache_key: "model-cache"),
               [Message.user("search")],
               tools: [Tools.web_search()],
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
    refute Map.has_key?(body, "deferred")

    assert {:ok, per_call_body} =
             ChatModel.request_body(
               ChatModel.new(model: "grok-4.3", prompt_cache_key: "model-cache"),
               [Message.user("search")],
               prompt_cache_key: "call-cache"
             )

    assert per_call_body["prompt_cache_key"] == "call-cache"
  end

  test "stop sequences reach only non-reasoning Chat Completions models and are rejected elsewhere" do
    for {module, model} <- [
          {ChatModel, "grok-4.3"},
          {ChatModel, "grok-4.20-0309-non-reasoning"},
          {ChatCompletionsModel, "grok-4.20-0309-reasoning"}
        ] do
      assert {:error, error} =
               module.request_body(module.new(model: model), [Message.user("stop check")], stop: ["END"])

      assert error.type == :unsupported_model_param
      assert error.details.params == [:stop]
    end

    assert {:ok, non_reasoning_chat_body} =
             ChatCompletionsModel.request_body(
               ChatCompletionsModel.new(model: "grok-4.20-0309-non-reasoning"),
               [Message.user("stop check")],
               stop: ["END"]
             )

    assert non_reasoning_chat_body["stop"] == ["END"]
  end

  # xAI's Responses API keeps `metadata` only for compatibility, and Chat
  # Completions has none.
  test "both APIs reject request metadata before transport" do
    for module <- [ChatModel, ChatCompletionsModel] do
      assert {:error, %Error{type: :unsupported_model_param, details: %{params: [:metadata]}}} =
               module.request_body(module.new(model: "grok-4.6"), [Message.user("hi")], metadata: %{source: "summary"})

      model = module.new(model: "grok-4.6", metadata: %{user_id: "user_123"})

      assert {:error, %Error{type: :unsupported_model_param, details: %{params: [:metadata]}}} =
               module.request_body(model, [Message.user("hi")])
    end
  end

  test "a model with metadata fails when it is created, with the error each call returns" do
    for api <- [:responses, :chat_completions] do
      assert {:error, %Error{type: :unsupported_model_param, details: %{params: [:metadata]}} = error} =
               Models.init_chat_model("xai:grok-4.6", api: api, api_key: "k", metadata: %{user_id: "user_123"})

      model =
        Models.init_chat_model!("xai:grok-4.6",
          api: api,
          api_key: "k",
          transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
          transport_opts: [parent: self()]
        )

      assert {:error, ^error} = CoreChatModel.invoke(model, [Message.user("hi")], metadata: %{user_id: "user_123"})
      refute_received {:fake_transport_request, _request}
    end

    # A param policy that lets a call send it lets the model take it.
    assert {:ok, %ChatModel{metadata: %{user_id: "user_123"}}} =
             Models.init_chat_model("xai:grok-4.6",
               api_key: "k",
               metadata: %{user_id: "user_123"},
               param_policy: :permissive
             )
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

  test "Chat Completions request body preserves extra options and deferred mode" do
    assert {:ok, body} =
             ChatCompletionsModel.request_body(
               ChatCompletionsModel.new(model: "grok-4.3"),
               [Message.user("search")],
               extra_body: %{custom_param: true},
               deferred: true,
               stream: true
             )

    assert body["model"] == "grok-4.3"
    assert body["messages"] == [%{"role" => "user", "content" => "search"}]
    assert body["custom_param"] == true
    assert body["deferred"] == true
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

  test "Chat Completions stream_response keeps the reasoning and citations an invoked reply has" do
    body = """
    data: {"id":"chatcmpl_xai","model":"grok-3-mini","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"I "},"finish_reason":null}]}

    data: {"id":"chatcmpl_xai","model":"grok-3-mini","choices":[{"index":0,"delta":{"reasoning_content":"counted."},"finish_reason":null}]}

    data: {"id":"chatcmpl_xai","model":"grok-3-mini","choices":[{"index":0,"delta":{"content":"27"},"finish_reason":null}]}

    data: {"id":"chatcmpl_xai","model":"grok-3-mini","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"citations":["https://docs.x.ai"]}

    data: {"id":"chatcmpl_xai","model":"grok-3-mini","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":7,"completion_tokens_details":{"reasoning_tokens":4}}}

    data: [DONE]
    """

    model =
      ChatCompletionsModel.new(
        model: "grok-3-mini",
        api_key: "xai-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/v1/chat/completions"},
          headers: [{"content-type", "text/event-stream"}, {"x-request-id", "req-1"}],
          body: body
        ]
      )

    assert {:ok, response} = ChatCompletionsModel.stream_response(model, [Message.user("count")])
    assert Message.text(response) == "27"
    assert response.metadata.reasoning_content == "I counted."
    assert response.metadata.citations == ["https://docs.x.ai"]
    assert response.response_metadata.request_id == "req-1"

    assert response.usage_metadata == %{
             input_tokens: 1,
             output_tokens: 6,
             total_tokens: 7,
             output_token_details: %{reasoning: 4}
           }
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

  test "stream_typed_events returns xAI Responses reasoning deltas as typed chunks" do
    body = """
    event: response.reasoning_text.delta
    data: {"type":"response.reasoning_text.delta","item_id":"rs_1","delta":"thinking"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"answer"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_xai","usage":{"total_tokens":3}}}

    data: [DONE]
    """

    model =
      ChatModel.new(
        model: "grok-4.3",
        api_key: "xai-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/v1/responses"},
          headers: [{"content-type", "text/event-stream"}],
          body: body
        ]
      )

    assert {:ok, stream} = CoreChatModel.stream_typed_events(model, [Message.user("events")])
    events = Enum.to_list(stream)

    assert Enum.any?(
             events,
             &match?(
               %{
                 event: %Events.MessageChunk{
                   chunk: %{content: [%ContentBlock.Reasoning{reasoning: "thinking"}]}
                 }
               },
               &1
             )
           )

    assert Enum.any?(events, &match?(%{event: %Events.Token{text: "answer"}}, &1))
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
        api_key: "test-key",
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

  test "model initializer resolves xAI chat identifiers" do
    for model <- ["grok-4.6", "grok-4.5", "grok-4.3"] do
      assert {:ok, %ChatModel{model: ^model}} = Models.init_chat_model("xai:" <> model)
    end

    assert {:ok, latest_alias} = Models.init_chat_model("xai:grok-4.5-latest")
    assert latest_alias.model == "grok-4.5-latest"

    assert {:ok, build_latest_alias} = Models.init_chat_model("xai:grok-build-latest")
    assert build_latest_alias.model == "grok-build-latest"

    assert {:ok, generic_latest_alias} = Models.init_chat_model("xai:grok-latest")
    assert generic_latest_alias.model == "grok-latest"

    assert {:ok, alias_model} = Models.init_chat_model("xai:grok-4")
    assert alias_model.model == "grok-4"

    assert {:error, deprecated} = Models.init_chat_model("grok-4-fast-reasoning")
    assert deprecated.type == :deprecated_model
    assert deprecated.details.replacement == "grok-4.3"
    assert deprecated.details.reasoning_effort == "low"

    assert {:ok, chat_completions} =
             Models.init_chat_model("xai:grok-4", api: :chat_completions)

    assert chat_completions.__struct__ == ChatCompletionsModel
  end

  test "structured output leaves dynamic empty object maps open for xAI" do
    schema = %{
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
    }

    assert {:ok, body} =
             ChatModel.request_body(ChatModel.new(model: "grok-4.3"), [Message.user("update crm")],
               response_format: %{name: "crm_updates", schema: schema, strict: true}
             )

    format = body["text"]["format"]

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
