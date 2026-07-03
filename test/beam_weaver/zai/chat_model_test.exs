defmodule BeamWeaver.ZAI.ChatModelTest do
  use ExUnit.Case

  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models
  alias BeamWeaver.ZAI.ChatModel
  alias BeamWeaver.ZAI.Client
  alias BeamWeaver.ZAI.Error
  alias BeamWeaver.ZAI.Messages
  alias BeamWeaver.ZAI.Streaming

  test "namespace and client constructors read Z.ai config defaults and derive endpoints" do
    with_config(
      :zai,
      [
        api_key: "zai-secret",
        base_url: "https://proxy.test/api/paas/v4"
      ],
      fn ->
        model = BeamWeaver.ZAI.chat_model(default_headers: [{"x-test-header", "beam-weaver-test"}])
        request = Client.request(%Client{endpoint: model.endpoint, api_key: model.api_key}, %{})

        assert model.endpoint == "https://proxy.test/api/paas/v4/chat/completions"
        assert model.api_key == "zai-secret"
        assert {"authorization", "Bearer zai-secret"} in request.headers
        assert {"user-agent", "beam_weaver-zai/0.1"} in request.headers
      end
    )
  end

  test "model constructor accepts Z.ai base_url alias" do
    model = ChatModel.new(base_url: "https://proxy.test/api/paas/v4")

    assert model.endpoint == "https://proxy.test/api/paas/v4/chat/completions"
  end

  test "request body maps GLM-5.2 params to Z.ai chat-completions shape" do
    response_schema = %{
      "title" => "Answer",
      "type" => "object",
      "required" => ["answer", "skip"],
      "properties" => %{
        "answer" => %{"type" => "string"},
        "skip" => %{"type" => "boolean"}
      }
    }

    assert {:ok, body} =
             ChatModel.request_body(
               ChatModel.new(),
               [Message.user("answer as JSON")],
               do_sample: true,
               temperature: 0.7,
               top_p: 0.9,
               max_output_tokens: 123,
               max_completion_tokens: 456,
               stop: ["END"],
               thinking: %{type: :enabled},
               reasoning_effort: :low,
               tool_stream: true,
               stream: true,
               stream_options: %{include_usage: true},
               request_id: "request-123",
               user_id: "user-123",
               response_format: %{name: "Answer", schema: response_schema, strict: true},
               tool_choice: :auto
             )

    assert body["model"] == "glm-5.2"

    assert [
             %{"role" => "system", "content" => schema_instruction},
             %{"role" => "user", "content" => "answer as JSON"}
           ] = body["messages"]

    assert schema_instruction =~ "BeamWeaver structured output contract"
    assert schema_instruction =~ "Required keys: answer, skip"
    assert schema_instruction =~ ~s("answer")
    assert schema_instruction =~ ~s("skip")
    assert body["do_sample"] == true
    assert body["temperature"] == 0.7
    assert body["top_p"] == 0.9
    assert body["max_tokens"] == 123
    refute Map.has_key?(body, "max_completion_tokens")
    assert body["stop"] == ["END"]
    assert body["thinking"] == %{"type" => "enabled"}
    assert body["reasoning_effort"] == "low"
    assert body["tool_stream"] == true
    assert body["stream_options"] == %{"include_usage" => true}
    assert body["request_id"] == "request-123"
    assert body["user_id"] == "user-123"
    assert body["response_format"] == %{"type" => "json_object"}
    assert body["tool_choice"] == "auto"
  end

  test "plain Z.ai JSON object response format does not inject schema instructions" do
    assert {:ok, body} =
             ChatModel.request_body(
               ChatModel.new(),
               [Message.user("answer as JSON")],
               response_format: %{type: :json_object}
             )

    assert body["messages"] == [%{"role" => "user", "content" => "answer as JSON"}]
    assert body["response_format"] == %{"type" => "json_object"}
  end

  test "request validation rejects unsupported GLM-5.2 options before transport" do
    assert {:error, tool_stream_error} =
             ChatModel.request_body(ChatModel.new(), [Message.user("hi")], tool_stream: true)

    assert tool_stream_error.type == :unsupported_model_param
    assert tool_stream_error.details.param == :tool_stream

    assert {:error, tool_choice_error} =
             ChatModel.request_body(ChatModel.new(), [Message.user("hi")],
               tool_choice: %{type: "function", function: %{name: "lookup"}}
             )

    assert tool_choice_error.type == :unsupported_model_param
    assert tool_choice_error.details.supported == ["auto"]

    assert {:error, format_error} =
             ChatModel.request_body(ChatModel.new(), [Message.user("hi")],
               response_format: %{type: "json_schema", json_schema: %{name: "Answer"}}
             )

    assert format_error.type == :invalid_response_format

    assert {:error, model_error} =
             ChatModel.request_body(%{ChatModel.new() | model: "glm-5.1"}, [Message.user("hi")])

    assert model_error.type == :unsupported_model
    assert model_error.details.expected == "zai:glm-5.2"
  end

  test "function tool validation enforces Z.ai name and count limits" do
    assert {:ok, body} =
             ChatModel.request_body(ChatModel.new(), [Message.user("weather")], tools: [weather_tool()])

    assert [%{"function" => %{"name" => "get_weather"}}] = body["tools"]

    bad_tool = %{
      "type" => "function",
      "function" => %{"name" => "bad.name", "parameters" => %{"type" => "object"}}
    }

    assert {:error, bad_name} =
             ChatModel.request_body(ChatModel.new(), [Message.user("weather")], tools: [bad_tool])

    assert bad_name.type == :invalid_request
    assert bad_name.details.pattern == "^[a-zA-Z0-9_-]{1,64}$"

    too_many_tools =
      Enum.map(1..129, fn index ->
        %{
          "type" => "function",
          "function" => %{
            "name" => "tool_#{index}",
            "parameters" => %{"type" => "object"}
          }
        }
      end)

    assert {:error, too_many} =
             ChatModel.request_body(ChatModel.new(), [Message.user("weather")], tools: too_many_tools)

    assert too_many.type == :invalid_request
    assert too_many.details.max == 128
  end

  test "text-only input rejects media content" do
    assert {:error, error} =
             ChatModel.request_body(
               ChatModel.new(),
               [Message.user([ContentBlock.text("inspect"), ContentBlock.image(%{url: "https://example.test/a.png"})])]
             )

    assert error.type == :unsupported_feature
    assert error.details.feature == :image
  end

  test "Chat Completions response preserves log IDs, usage details, and estimated cost" do
    response = %{
      "_beamweaver_response_header_metadata" => %{
        headers: %{x_log_id: "chatcmpl_zai"},
        request_id: "chatcmpl_zai"
      },
      "id" => "chatcmpl_zai",
      "request_id" => "chatcmpl_zai",
      "created" => 1_782_040_000,
      "model" => "glm-5.2",
      "object" => "chat.completion",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => "done",
            "reasoning_content" => "plan",
            "tool_calls" => [
              %{
                "id" => "call_weather",
                "type" => "function",
                "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Paris"})}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "completion_tokens" => 5,
        "total_tokens" => 15,
        "prompt_tokens_details" => %{"cached_tokens" => 4},
        "completion_tokens_details" => %{"reasoning_tokens" => 3}
      }
    }

    assert {:ok, message} = Messages.chat_response_to_message(response)
    assert Message.text(message) == "done"
    assert message.metadata.request_id == "chatcmpl_zai"
    assert message.metadata.x_log_id == "chatcmpl_zai"
    assert message.metadata.headers == %{x_log_id: "chatcmpl_zai"}
    assert message.metadata.model_provider == "zai"
    assert message.metadata.reasoning_content == "plan"
    assert message.status == "tool_calls"

    assert [%ToolCall{name: "get_weather", args: %{"city" => "Paris"}}] = message.tool_calls
    assert message.usage_metadata.input_token_details.cache_read == 4
    assert message.usage_metadata.output_token_details.reasoning == 3
    assert_in_delta message.usage_metadata.total_cost, 0.00003144, 0.000000001
    assert_in_delta message.metadata.estimated_cost, 0.00003144, 0.000000001
  end

  test "stream body reconstructs text, reasoning, final usage, length, and tool-call fragments" do
    body = """
    data: {"id":"chatcmpl_zai_stream","model":"glm-5.2","choices":[{"index":0,"delta":{"reasoning_content":"plan "},"finish_reason":null}]}

    data: {"id":"chatcmpl_zai_stream","model":"glm-5.2","choices":[{"index":0,"delta":{"content":"po","tool_calls":[{"index":0,"id":"call_weather","type":"function","function":{"name":"get_weather","arguments":"{\\\"city\\\":"}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl_zai_stream","model":"glm-5.2","choices":[{"index":0,"delta":{"content":"ng","tool_calls":[{"index":0,"type":"function","function":{"arguments":"\\\"Paris\\\"}"}}]},"finish_reason":"length"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5,"prompt_tokens_details":{"cached_tokens":1},"completion_tokens_details":{"reasoning_tokens":1}}}

    data: [DONE]
    """

    assert Streaming.text_deltas(body) == ["po", "ng"]

    assert {:ok, message} =
             Streaming.stream_body_to_message(body,
               header_metadata: %{
                 headers: %{x_log_id: "chatcmpl_zai_stream"},
                 request_id: "chatcmpl_zai_stream"
               }
             )

    assert Message.text(message) == "pong"
    assert message.status == "length"
    assert message.metadata.request_id == "chatcmpl_zai_stream"
    assert message.metadata.x_log_id == "chatcmpl_zai_stream"
    assert message.response_metadata.headers == %{x_log_id: "chatcmpl_zai_stream"}
    assert message.metadata.reasoning_content == "plan "
    assert message.usage_metadata.input_token_details.cache_read == 1
    assert message.usage_metadata.output_token_details.reasoning == 1
    assert [%ToolCall{name: "get_weather", args: %{"city" => "Paris"}}] = message.tool_calls
  end

  test "stream body keeps deltas from chunks without top-level ids" do
    body = """
    data: {"id":"chatcmpl_zai_no_id","model":"glm-5.2","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

    data: {"choices":[{"index":0,"delta":{"content":"po"},"finish_reason":null}]}

    data: {"choices":[{"index":0,"delta":{"content":"ng"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}

    data: [DONE]
    """

    assert {:ok, message} = Streaming.stream_body_to_message(body)
    assert message.id == "chatcmpl_zai_no_id"
    assert Message.text(message) == "pong"
    assert message.usage_metadata.total_tokens == 5
  end

  test "invokes Z.ai Chat Completions through fake transport and normalizes errors" do
    model =
      ChatModel.new(
        api_key: "zai-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          expect: %{
            method: :post,
            path: "/api/paas/v4/chat/completions",
            json: %{
              "model" => "glm-5.2",
              "messages" => [%{"role" => "user", "content" => "ping"}],
              "stream" => false
            }
          },
          headers: [{"content-type", "application/json"}, {"x-log-id", "chatcmpl_zai"}],
          body: %{
            "id" => "chatcmpl_zai",
            "request_id" => "chatcmpl_zai",
            "model" => "glm-5.2",
            "choices" => [
              %{
                "message" => %{"role" => "assistant", "content" => "pong"},
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          }
        ]
      )

    assert {:ok, response} = CoreChatModel.invoke(model, [Message.user("ping")])
    assert Message.text(response) == "pong"
    assert response.metadata.x_log_id == "chatcmpl_zai"
    assert response.response_metadata.headers == %{x_log_id: "chatcmpl_zai"}
    refute Map.has_key?(response.response_metadata.transport, :headers)

    assert response.usage_metadata == %{
             input_cost: 0.0000014,
             input_cost_details: %{cache_read: 0.0, uncached: 0.0000014},
             input_tokens: 1,
             output_cost: 0.0000044,
             output_cost_details: %{text: 0.0000044},
             output_tokens: 1,
             total_cost: 0.0000058,
             total_tokens: 2
           }

    assert_received {:fake_transport_request, request}
    assert {"authorization", "Bearer zai-secret"} in request.headers

    error_model =
      ChatModel.new(
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/api/paas/v4/chat/completions"},
          status: 429,
          headers: [{"x-log-id", "chatcmpl_zai_rate_limit"}],
          body: %{
            "error" => %{
              "type" => "rate_limit_error",
              "message" => "rate limited",
              "code" => "rate_limit"
            }
          }
        ]
      )

    assert {:error, %Error{type: :rate_limit_error} = error} =
             CoreChatModel.invoke(error_model, [Message.user("rate limit")])

    assert error.details.status == 429
    assert error.details.retryable
    assert error.details.request_id == "chatcmpl_zai_rate_limit"
  end

  test "insufficient balance is normalized as non-retryable quota error" do
    error_model =
      ChatModel.new(
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/api/paas/v4/chat/completions"},
          status: 429,
          headers: [{"x-log-id", "chatcmpl_zai_balance"}],
          body: %{
            "error" => %{
              "code" => "1113",
              "message" => "Insufficient balance or no resource package. Please recharge."
            }
          }
        ]
      )

    assert {:error, %Error{type: :quota_error} = error} =
             CoreChatModel.invoke(error_model, [Message.user("balance")])

    assert error.message == "Insufficient balance or no resource package. Please recharge."
    assert error.details.status == 429
    refute error.details.retryable
    refute BeamWeaver.RetryPredicates.transient?(error)
  end

  test "model initializer supports only explicit zai:glm-5.2" do
    assert {:ok, model} = Models.init_chat_model("zai:glm-5.2")
    assert model.__struct__ == ChatModel
    assert model.model == "glm-5.2"
    assert model.profile.provider == :zai
    assert model.profile.max_input_tokens == 1_000_000
    assert model.profile.max_output_tokens == 131_072
    assert model.profile.reasoning_output
    assert model.profile.tool_calling
    assert model.profile.structured_output
    assert model.profile.chat_completions_api
    refute model.profile.responses_api

    assert {:error, invalid} = Models.init_chat_model("glm-5.2")
    assert invalid.type == :invalid_model
    assert invalid.details.expected == "zai:glm-5.2"

    assert {:error, unsupported} = Models.init_chat_model("zai:glm-5.1")
    assert unsupported.type == :unsupported_model
    assert unsupported.details.expected == "zai:glm-5.2"
  end

  defp weather_tool do
    Tool.from_function!(
      name: "get_weather",
      description: "Return current weather for a city.",
      input_schema: %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      },
      handler: fn args, _opts -> args end
    )
  end

  defp with_config(group, values, fun) do
    BeamWeaver.TestSupport.ConfigHelper.put_config(group, values)
    fun.()
  end
end
