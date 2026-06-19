defmodule BeamWeaver.Moonshot.ChatModelTest do
  use ExUnit.Case

  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Models
  alias BeamWeaver.Moonshot.ChatModel
  alias BeamWeaver.Moonshot.Client
  alias BeamWeaver.Moonshot.Error
  alias BeamWeaver.Moonshot.Messages
  alias BeamWeaver.Moonshot.Tools
  alias BeamWeaver.Stream.Events

  test "namespace and client constructors read Moonshot config defaults and derive endpoints" do
    with_config(
      :moonshot,
      [
        api_key: "moonshot-secret",
        base_url: "https://proxy.test/v1"
      ],
      fn ->
        model =
          BeamWeaver.Moonshot.chat_model(default_headers: [{"x-test-header", "beam-weaver-test"}])

        request = Client.request(%Client{endpoint: model.endpoint, api_key: model.api_key}, %{})

        assert model.endpoint == "https://proxy.test/v1/chat/completions"

        assert model.count_tokens_endpoint ==
                 "https://proxy.test/v1/tokenizers/estimate-token-count"

        assert model.api_key == "moonshot-secret"
        assert {"authorization", "Bearer moonshot-secret"} in request.headers
        assert {"user-agent", "beam_weaver-moonshot/0.1"} in request.headers
      end
    )
  end

  test "model constructor accepts Moonshot base_url alias" do
    model = ChatModel.new(base_url: "https://proxy.test/v1")

    assert model.endpoint == "https://proxy.test/v1/chat/completions"
    assert model.count_tokens_endpoint == "https://proxy.test/v1/tokenizers/estimate-token-count"
  end

  test "request body supports K2.6 thinking, structured output, partial mode, cache key, and safety identifier" do
    assert {:ok, body} =
             ChatModel.request_body(
               ChatModel.new(model: "kimi-k2.6"),
               [
                 Message.user("answer as JSON"),
                 Message.assistant("prefix",
                   metadata: %{partial: true, reasoning_content: "plan"}
                 )
               ],
               thinking: %{type: :enabled, keep: :all},
               response_format: %{
                 name: "Answer",
                 schema: %{type: :object, properties: %{answer: %{type: :string}}}
               },
               prompt_cache_key: "session-1",
               safety_identifier: "user-123",
               max_tokens: 128
             )

    assert body["model"] == "kimi-k2.6"
    assert body["thinking"] == %{"type" => "enabled", "keep" => "all"}
    assert body["response_format"]["type"] == "json_schema"
    assert body["response_format"]["json_schema"]["name"] == "Answer"
    assert body["prompt_cache_key"] == "session-1"
    assert body["safety_identifier"] == "user-123"
    assert body["max_completion_tokens"] == 128

    assert List.last(body["messages"]) == %{
             "role" => "assistant",
             "content" => "prefix",
             "partial" => true,
             "reasoning_content" => "plan"
           }
  end

  test "request body encodes image and video input and rejects ordinary remote media URLs" do
    assert {:ok, body} =
             ChatModel.request_body(
               ChatModel.new(model: "kimi-k2.6"),
               [
                 Message.user([
                   ContentBlock.text("inspect"),
                   ContentBlock.image(%{data: "image-bytes", mime_type: "image/png"}),
                   ContentBlock.video(%{url: "ms://file-video"})
                 ])
               ]
             )

    [message] = body["messages"]

    assert %{
             "type" => "image_url",
             "image_url" => %{"url" => "data:image/png;base64,image-bytes"}
           } in message["content"]

    assert %{"type" => "video_url", "video_url" => %{"url" => "ms://file-video"}} in message[
             "content"
           ]

    assert {:error, error} =
             ChatModel.request_body(
               ChatModel.new(model: "kimi-k2.6"),
               [Message.user([ContentBlock.image(%{url: "https://example.test/image.png"})])]
             )

    assert error.type == :unsupported_feature
    assert error.details.feature == :image_url
  end

  test "K2.6 fixed sampling params and partial JSON mode fail before transport" do
    assert {:error, temp_error} =
             ChatModel.request_body(ChatModel.new(model: "kimi-k2.6"), [Message.user("hi")], temperature: 0.2)

    assert temp_error.type == :unsupported_model_param
    assert temp_error.details.param == :temperature

    assert {:ok, body} =
             ChatModel.request_body(ChatModel.new(model: "kimi-k2.6"), [Message.user("hi")],
               thinking: %{type: :disabled},
               temperature: 0.6,
               top_p: 0.95,
               n: 1,
               presence_penalty: 0,
               frequency_penalty: 0
             )

    assert body["thinking"] == %{"type" => "disabled"}
    assert body["temperature"] == 0.6

    assert {:error, partial_error} =
             ChatModel.request_body(
               ChatModel.new(model: "kimi-k2.6"),
               [Message.assistant("{", metadata: %{partial: true})],
               response_format: %{type: "json_object"}
             )

    assert partial_error.type == :invalid_request
  end

  test "K2.5 uses the same fixed sampling params as K2.6" do
    assert {:error, temp_error} =
             ChatModel.request_body(ChatModel.new(model: "kimi-k2.5"), [Message.user("hi")], temperature: 0.2)

    assert temp_error.type == :unsupported_model_param
    assert temp_error.details.model == "kimi-k2.5"
    assert temp_error.details.param == :temperature
    assert temp_error.details.supported == 1.0

    assert {:ok, body} =
             ChatModel.request_body(ChatModel.new(model: "kimi-k2.5"), [Message.user("hi")],
               thinking: %{type: :disabled},
               temperature: 0.6,
               top_p: 0.95,
               n: 1,
               presence_penalty: 0,
               frequency_penalty: 0
             )

    assert body["model"] == "kimi-k2.5"
    assert body["thinking"] == %{"type" => "disabled"}
    assert body["temperature"] == 0.6
  end

  test "K2.7 Code supports only enabled thinking and automatic tool choice" do
    assert {:ok, body} =
             ChatModel.request_body(ChatModel.new(model: "kimi-k2.7-code"), [Message.user("hi")],
               temperature: 1.0,
               top_p: 0.95,
               n: 1,
               presence_penalty: 0,
               frequency_penalty: 0
             )

    assert body["model"] == "kimi-k2.7-code"

    assert {:error, thinking_error} =
             ChatModel.request_body(ChatModel.new(model: "kimi-k2.7-code"), [Message.user("hi")],
               thinking: %{type: :disabled}
             )

    assert thinking_error.type == :unsupported_model_param
    assert thinking_error.details.model == "kimi-k2.7-code"
    assert thinking_error.details.param == :thinking
    assert thinking_error.details.supported == [%{"type" => "enabled"}]

    assert {:error, tool_choice_error} =
             ChatModel.request_body(ChatModel.new(model: "kimi-k2.7-code-highspeed"), [Message.user("hi")],
               tool_choice: %{type: "function", function: %{name: "lookup_weather"}}
             )

    assert tool_choice_error.type == :unsupported_model_param
    assert tool_choice_error.details.model == "kimi-k2.7-code-highspeed"
    assert tool_choice_error.details.param == :tool_choice
    assert tool_choice_error.details.supported == ["auto", "none"]

    assert {:error, temp_error} =
             ChatModel.request_body(ChatModel.new(model: "kimi-k2.7-code"), [Message.user("hi")], temperature: 0.6)

    assert temp_error.type == :unsupported_model_param
    assert temp_error.details.model == "kimi-k2.7-code"
    assert temp_error.details.param == :temperature
    assert temp_error.details.supported == 1.0
  end

  test "function tools and built-in web search are rendered with Kimi rules" do
    beam_weaver_tool = %Tool{
      name: "lookup_account",
      description: "Lookup an account",
      input_schema: %{
        "type" => "object",
        "properties" => %{"account_id" => %{"type" => "string"}},
        "required" => ["account_id"]
      },
      handler: fn _args, _opts -> {:ok, "ok"} end
    }

    function_tool = %{
      "type" => "function",
      "function" => %{
        "name" => "lookup_weather",
        "description" => "Lookup weather",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    }

    assert {:ok, body} =
             ChatModel.request_body(
               ChatModel.new(model: "kimi-k2.6"),
               [Message.user("search")],
               tools: [beam_weaver_tool, function_tool, Tools.web_search()],
               thinking: %{type: :disabled},
               tool_choice: :auto
             )

    assert [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "lookup_account",
                 "parameters" => %{
                   "properties" => %{"account_id" => %{"type" => "string"}},
                   "required" => ["account_id"],
                   "type" => "object"
                 }
               }
             },
             ^function_tool,
             %{"type" => "builtin_function"}
           ] = body["tools"]

    assert body["tool_choice"] == "auto"

    assert {:error, error} =
             ChatModel.request_body(
               ChatModel.new(model: "kimi-k2.6"),
               [Message.user("search")],
               tools: [Tools.web_search()]
             )

    assert error.type == :unsupported_feature
    assert error.details.feature == :web_search
  end

  test "deprecated OpenAI function params are rejected" do
    assert {:error, error} =
             ChatModel.request_body(
               ChatModel.new(model: "kimi-k2.6"),
               [Message.user("hi")],
               functions: []
             )

    assert error.type == :unsupported_model_param
    assert :functions in error.details.params
  end

  test "Chat Completions response preserves content, reasoning, tools, provider metadata, and cached tokens" do
    response = %{
      "id" => "chatcmpl_kimi",
      "model" => "kimi-k2.6",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => "I will call the tool.",
            "reasoning_content" => "Need current weather.",
            "tool_calls" => [
              %{
                "id" => "call_weather",
                "type" => "function",
                "function" => %{
                  "name" => "lookup_weather",
                  "arguments" => ~s({"city":"Paris"})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "completion_tokens" => 20,
        "total_tokens" => 30,
        "cached_tokens" => 6,
        "completion_tokens_details" => %{"reasoning_tokens" => 7}
      }
    }

    assert {:ok, message} = Messages.chat_response_to_message(response)
    assert Message.text(message) == "I will call the tool."

    assert [%{type: :reasoning, reasoning: "Need current weather."} | _] =
             message.content

    assert message.metadata.model_provider == "moonshot"
    assert message.metadata.reasoning_content == "Need current weather."
    assert message.status == "tool_calls"

    assert [%ToolCall{name: "lookup_weather", args: %{"city" => "Paris"}}] =
             message.tool_calls

    assert message.usage_metadata == %{
             input_tokens: 10,
             output_tokens: 20,
             total_tokens: 30,
             input_token_details: %{cache_read: 6},
             output_token_details: %{reasoning: 7}
           }
  end

  test "renders assistant tool call ids with the provider id used by following tool messages" do
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
      Message.tool("done", tool_call_id: "task:0", name: "task")
    ]

    assert {:ok, moonshot_messages} = Messages.to_chat_messages(messages)

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
           ] = moonshot_messages
  end

  test "invokes Moonshot Chat Completions through fake transport" do
    model =
      ChatModel.new(
        model: "kimi-k2.6",
        api_key: "moonshot-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          expect: %{
            method: :post,
            path: "/v1/chat/completions",
            json: %{
              "model" => "kimi-k2.6",
              "messages" => [%{"role" => "user", "content" => "ping"}],
              "stream" => false
            }
          },
          body: %{
            "id" => "chatcmpl_kimi",
            "model" => "kimi-k2.6",
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
    assert response.metadata.model_provider == "moonshot"
    assert response.usage_metadata == %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
    assert response.response_metadata.model.provider == :moonshot

    assert_received {:fake_transport_request, request}
    assert {"authorization", "Bearer moonshot-secret"} in request.headers
  end

  test "stream_response reconstructs reasoning, text, tool calls, and usage" do
    body = """
    data: {"id":"chatcmpl_kimi","model":"kimi-k2.6","choices":[{"index":0,"delta":{"reasoning_content":"plan "},"finish_reason":null}]}

    data: {"id":"chatcmpl_kimi","model":"kimi-k2.6","choices":[{"index":0,"delta":{"content":"po"},"finish_reason":null}]}

    data: {"id":"chatcmpl_kimi","model":"kimi-k2.6","choices":[{"index":0,"delta":{"content":"ng","tool_calls":[{"index":0,"id":"call_1","function":{"name":"lookup_weather","arguments":"{}"}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl_kimi","model":"kimi-k2.6","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3,"cached_tokens":1}}

    data: {"id":"chatcmpl_kimi","model":"kimi-k2.6","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3,"cached_tokens":1}}

    data: [DONE]
    """

    model =
      ChatModel.new(
        model: "kimi-k2.6",
        api_key: "moonshot-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{
            method: :post,
            path: "/v1/chat/completions",
            json: %{
              "model" => "kimi-k2.6",
              "messages" => [%{"role" => "user", "content" => "stream"}],
              "stream" => true,
              "stream_options" => %{"include_usage" => true}
            }
          },
          headers: [{"content-type", "text/event-stream"}],
          body: body
        ]
      )

    assert {:ok, response} = ChatModel.stream_response(model, [Message.user("stream")])
    assert Message.text(response) == "pong"
    assert response.metadata.model_provider == "moonshot"
    assert response.metadata.reasoning_content == "plan "
    assert response.status == "tool_calls"
    assert [%ToolCall{name: "lookup_weather", args: %{}}] = response.tool_calls
    assert response.usage_metadata.input_token_details.cache_read == 1
  end

  test "stream_events returns envelopes tagged with Moonshot invocation metadata" do
    body = """
    data: {"id":"chatcmpl_kimi","model":"kimi-k2.6","choices":[{"index":0,"delta":{"reasoning_content":"think"},"finish_reason":null}]}

    data: {"id":"chatcmpl_kimi","model":"kimi-k2.6","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}

    data: {"id":"chatcmpl_kimi","model":"kimi-k2.6","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}

    data: [DONE]
    """

    model =
      ChatModel.new(
        model: "kimi-k2.6",
        api_key: "moonshot-secret",
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
    assert Enum.any?(events, &(&1.metadata[:block_type] == :reasoning))
    assert Enum.all?(events, &(&1.metadata.provider == :moonshot))
    assert Enum.all?(events, &(&1.metadata.model_provider == :moonshot))
  end

  test "token counting uses Moonshot estimate endpoint" do
    model =
      ChatModel.new(
        model: "kimi-k2.6",
        api_key: "moonshot-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{
            method: :post,
            path: "/v1/tokenizers/estimate-token-count",
            json: %{
              "model" => "kimi-k2.6",
              "messages" => [%{"role" => "user", "content" => "count me"}]
            }
          },
          body: %{"data" => %{"total_tokens" => 4}}
        ]
      )

    assert {:ok, 4} = ChatModel.count_tokens(model, "count me")
  end

  test "Moonshot context_length_exceeded HTTP errors are normalized as context overflow" do
    model =
      ChatModel.new(
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/v1/chat/completions"},
          status: 400,
          body: %{
            "error" => %{
              "type" => "invalid_request_error",
              "message" => "Input token length too long",
              "code" => "context_length_exceeded"
            }
          }
        ]
      )

    assert {:error, %Error{type: :context_overflow} = error} =
             CoreChatModel.invoke(model, [Message.user("test")])

    assert error.details.status == 400
    assert error.details.code == "context_length_exceeded"
    assert error.details.error["type"] == "invalid_request_error"
  end

  test "Moonshot auth, quota, and overloaded HTTP errors are normalized from provider codes" do
    for {status, code, expected_type} <- [
          {401, "invalid_authentication_error", :authentication_error},
          {429, "exceeded_current_quota_error", :quota_error},
          {503, "engine_overloaded_error", :overloaded_error}
        ] do
      model =
        ChatModel.new(
          transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
          transport_opts: [
            expect: %{method: :post, path: "/v1/chat/completions"},
            status: status,
            body: %{
              "error" => %{
                "type" => "api_error",
                "message" => "failed",
                "code" => code
              }
            }
          ]
        )

      assert {:error, %Error{type: ^expected_type} = error} =
               CoreChatModel.invoke(model, [Message.user("test")])

      assert error.details.status == status
      assert error.details.code == code
    end
  end

  test "model initializer supports Moonshot prefix, rejects aliases, and reports deprecated models" do
    assert {:ok, code_model} = Models.init_chat_model("moonshot:kimi-k2.7-code")
    assert code_model.__struct__ == ChatModel
    assert code_model.model == "kimi-k2.7-code"
    assert code_model.profile.extra.thinking_modes == [:enabled]
    assert code_model.profile.extra.model_category == :coding

    assert {:ok, highspeed_model} = Models.init_chat_model("moonshot:kimi-k2.7-code-highspeed")
    assert highspeed_model.model == "kimi-k2.7-code-highspeed"
    assert highspeed_model.profile.extra.highspeed

    assert {:ok, model} = Models.init_chat_model("moonshot:kimi-k2.6")
    assert model.__struct__ == ChatModel
    assert model.model == "kimi-k2.6"
    assert model.profile.provider == :moonshot
    assert model.profile.chat_completions_api
    refute model.profile.responses_api

    assert {:ok, k25_model} = Models.init_chat_model("moonshot:kimi-k2.5")
    assert k25_model.model == "kimi-k2.5"
    assert k25_model.profile.extra.thinking_modes == [:enabled, :disabled]

    assert {:error, invalid} = Models.init_chat_model("kimi-k2.6")
    assert invalid.type == :invalid_model
    assert invalid.details.expected == "moonshot:kimi-k2.6"

    assert {:error, unsupported} = Models.init_chat_model("kimi:kimi-k2.6")
    assert unsupported.type == :unsupported_provider

    assert {:error, deprecated} = Models.init_chat_model("moonshot:kimi-latest")
    assert deprecated.type == :deprecated_model
    assert deprecated.details.replacement == "kimi-k2.6"
    assert deprecated.details.expected == "moonshot:kimi-k2.6"
  end

  defp with_config(group, values, fun) do
    BeamWeaver.TestSupport.ConfigHelper.put_config(group, values)
    fun.()
  end
end
