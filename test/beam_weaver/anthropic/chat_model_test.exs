defmodule BeamWeaver.Anthropic.ChatModelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.ChatModel
  alias BeamWeaver.Anthropic.Client
  alias BeamWeaver.Anthropic.Error
  alias BeamWeaver.Anthropic.OutputParsers
  alias BeamWeaver.Anthropic.Tools
  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Models

  test "constructor accepts native options, profile defaults, and streaming intent" do
    model =
      ChatModel.new(
        model: "claude-sonnet-4-5",
        endpoint: "https://proxy.test/v1/messages",
        count_tokens_endpoint: "https://proxy.test/v1/messages/count_tokens"
      )

    assert model.model == "claude-sonnet-4-5"
    assert model.endpoint == "https://proxy.test/v1/messages"
    assert model.count_tokens_endpoint == "https://proxy.test/v1/messages/count_tokens"
    assert model.max_tokens == 64_000

    assert ChatModel.should_stream?(%ChatModel{streaming: true})
    assert ChatModel.should_stream?(%ChatModel{}, stream: true)
    refute ChatModel.should_stream?(%ChatModel{})
  end

  test "namespace constructor preserves explicit endpoints" do
    model =
      BeamWeaver.Anthropic.chat_model(
        endpoint: "https://proxy.test/v1/messages",
        count_tokens_endpoint: "https://proxy.test/v1/messages/count_tokens"
      )

    assert model.endpoint == "https://proxy.test/v1/messages"
    assert model.count_tokens_endpoint == "https://proxy.test/v1/messages/count_tokens"
  end

  test "client constructor reads config defaults and builds Anthropic headers" do
    with_config(
      :anthropic,
      [
        api_key: "env-secret"
      ],
      fn ->
        client =
          Client.new(
            betas: ["tools-beta"],
            default_headers: [{"user-agent", "beam-weaver-test"}]
          )

        request = Client.request(client, %{"model" => "claude-haiku-4-5-20251001"})

        assert request.url == "https://api.anthropic.com/v1/messages"
        assert {"x-api-key", "env-secret"} in request.headers
        assert {"anthropic-version", "2023-06-01"} in request.headers
        assert {"anthropic-beta", "tools-beta"} in request.headers
        assert {"user-agent", "beam-weaver-test"} in request.headers
      end
    )
  end

  test "invokes Anthropic Messages API through fake transport and decodes assistant text" do
    model =
      ChatModel.new(
        model: "claude-haiku-4-5-20251001",
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          expect: %{
            method: :post,
            path: "/v1/messages",
            json: %{
              "model" => "claude-haiku-4-5-20251001",
              "max_tokens" => 64_000,
              "messages" => [%{"role" => "user", "content" => "ping"}],
              "stream" => false
            }
          },
          body: %{
            "id" => "msg_fake",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-haiku-4-5-20251001",
            "content" => [%{"type" => "text", "text" => "pong"}],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }
        ]
      )

    assert {:ok, %Message{} = response} = CoreChatModel.invoke(model, [Message.user("ping")])
    assert Message.text(response) == "pong"
    assert response.usage_metadata == %{input_tokens: 1, output_tokens: 1, total_tokens: 2}

    assert_received {:fake_transport_request, request}
    assert {"x-api-key", "anthropic-secret"} in request.headers
    assert {"anthropic-version", "2023-06-01"} in request.headers
  end

  test "request body includes tools, structured output, thinking, mcp betas, and reused container" do
    model =
      ChatModel.new(
        model: "claude-sonnet-4-5",
        thinking: %{type: :enabled, budget_tokens: 1024},
        reuse_last_container: true
      )

    previous =
      Message.assistant("done",
        response_metadata: %{container: %{"id" => "container_123"}}
      )

    assert {:ok, body} =
             ChatModel.request_body(
               model,
               [Message.user("run"), previous, Message.user("again")],
               tools: [Tools.web_fetch()],
               response_format: %{schema: %{type: :object, properties: %{ok: %{type: :boolean}}}},
               mcp_servers: [%{type: :url, url: "https://mcp.example.test/mcp", name: "mcp"}],
               cache_control: %{type: :ephemeral},
               metadata: %{user_id: "user_123"},
               service_tier: :auto,
               diagnostics: %{trace: true},
               speed: :standard,
               user_profile_id: "profile_123",
               effort: :medium,
               parallel_tool_calls: false,
               tool_choice: :auto,
               stream: true
             )

    assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 1024}
    assert body["container"] == "container_123"
    assert body["cache_control"] == %{"type" => "ephemeral"}
    assert body["metadata"] == %{"user_id" => "user_123"}
    assert body["service_tier"] == "auto"
    assert body["diagnostics"] == %{"trace" => true}
    assert body["speed"] == "standard"
    assert body["user_profile_id"] == "profile_123"
    assert body["tools"] == [%{"type" => "web_fetch_20260309"}]
    assert body["tool_choice"] == %{"type" => "auto", "disable_parallel_tool_use" => true}
    assert body["output_config"]["effort"] == "medium"
    assert body["output_config"]["format"]["type"] == "json_schema"
    assert "web-fetch-2026-03-09" in body["betas"]
    assert "mcp-client-2025-11-20" in body["betas"]
  end

  test "inferred betas are sent as the anthropic-beta header, not in the request body" do
    model =
      ChatModel.new(
        model: "claude-sonnet-4-5",
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          body: %{
            "id" => "msg_fake",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-sonnet-4-5",
            "content" => [%{"type" => "text", "text" => "ok"}],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }
        ]
      )

    assert {:ok, %Message{}} =
             CoreChatModel.invoke(model, [Message.user("go")], tools: [Tools.web_fetch()])

    assert_received {:fake_transport_request, request}

    # The inferred beta is enabled via the anthropic-beta header...
    assert Enum.any?(request.headers, fn
             {"anthropic-beta", value} -> String.contains?(value, "web-fetch-2026-03-09")
             _ -> false
           end)

    # ...and is no longer left in the JSON body, where Anthropic would ignore it.
    refute Map.has_key?(request.json, "betas")
  end

  test "explicit container and count-token-only options match Anthropic schema" do
    model = ChatModel.new(model: "claude-sonnet-4-6")

    previous =
      Message.assistant("done",
        response_metadata: %{container: %{"id" => "container_old"}}
      )

    assert {:ok, body} =
             ChatModel.request_body(
               model,
               [Message.user("start"), previous, Message.user("again")],
               container: "container_explicit",
               reuse_last_container: true
             )

    assert body["container"] == "container_explicit"

    assert {:ok, count_body} =
             BeamWeaver.Anthropic.ChatModel.RequestBuilder.count_tokens_body(
               model,
               [Message.user("count")],
               cache_control: %{type: :ephemeral},
               thinking: %{type: :enabled, budget_tokens: 1024},
               tool_choice: :auto,
               output_config: %{effort: :low},
               mcp_servers: [%{type: :url, url: "https://mcp.example.test/mcp", name: "mcp"}],
               speed: :standard
             )

    assert count_body["cache_control"] == %{"type" => "ephemeral"}
    assert count_body["thinking"] == %{"type" => "enabled", "budget_tokens" => 1024}
    assert count_body["tool_choice"] == %{"type" => "auto"}
    assert count_body["output_config"] == %{"effort" => "low"}

    assert count_body["mcp_servers"] == [
             %{"type" => "url", "url" => "https://mcp.example.test/mcp", "name" => "mcp"}
           ]

    assert count_body["speed"] == "standard"
    assert "mcp-client-2025-11-20" in count_body["betas"]
  end

  test "Claude Opus 4.8 rejects deprecated sampling controls before transport" do
    model = ChatModel.new(model: "claude-opus-4-8")

    assert {:error, error} =
             ChatModel.request_body(model, [Message.user("hello")],
               temperature: 0.5,
               top_k: 5,
               top_p: 0.9
             )

    assert error.type == :unsupported_model_param
    assert error.details.provider == :anthropic
    assert error.details.model == "claude-opus-4-8"
    assert Enum.sort(error.details.params) == [:temperature, :top_k, :top_p]

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("hello")],
               temperature: 1.0,
               top_p: 0.99
             )

    assert body["temperature"] == 1.0
    assert body["top_p"] == 0.99
    refute Map.has_key?(body, "top_k")
  end

  test "Claude Opus 4.8 requires adaptive thinking when thinking is enabled" do
    model = ChatModel.new(model: "claude-opus-4-8")

    assert {:error, error} =
             ChatModel.request_body(model, [Message.user("hello")], thinking: %{type: :enabled, budget_tokens: 1024})

    assert error.type == :unsupported_model_param
    assert error.details.params == [:thinking]
    assert error.details.reason =~ "adaptive thinking"

    assert {:error, count_error} =
             BeamWeaver.Anthropic.ChatModel.RequestBuilder.count_tokens_body(
               model,
               [Message.user("hello")],
               thinking: %{type: :enabled, budget_tokens: 1024}
             )

    assert count_error.details.params == [:thinking]

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("hello")],
               thinking: %{type: :adaptive},
               effort: :high
             )

    assert body["thinking"] == %{"type" => "adaptive"}
    assert body["output_config"] == %{"effort" => "high"}
  end

  test "stream and stream_response consume Anthropic SSE fixtures" do
    body = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_stream","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001","content":[],"usage":{"input_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"po"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ng"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}
    """

    model =
      ChatModel.new(
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{
            method: :post,
            path: "/v1/messages",
            json: %{
              "model" => "claude-haiku-4-5-20251001",
              "max_tokens" => 64_000,
              "messages" => [%{"role" => "user", "content" => "stream"}],
              "stream" => true
            }
          },
          headers: [{"content-type", "text/event-stream"}],
          body: body
        ]
      )

    assert {:ok, chunks} = ChatModel.stream(model, [Message.user("stream")])
    assert Enum.join(chunks) == "pong"

    assert {:ok, response} = ChatModel.stream_response(model, [Message.user("stream")])
    assert Message.text(response) == "pong"
    assert response.status == "end_turn"
  end

  test "count_tokens uses Anthropic count_tokens endpoint" do
    model =
      ChatModel.new(
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{
            method: :post,
            path: "/v1/messages/count_tokens",
            json: %{
              "model" => "claude-haiku-4-5-20251001",
              "messages" => [%{"role" => "user", "content" => "hello"}]
            }
          },
          body: %{"input_tokens" => 7}
        ]
      )

    assert {:ok, 7} = ChatModel.count_tokens(model, [Message.user("hello")])
  end

  test "Anthropic prompt-length HTTP errors are normalized as context overflow" do
    model =
      ChatModel.new(
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/v1/messages"},
          status: 400,
          body: %{
            "error" => %{
              "type" => "invalid_request_error",
              "message" => "prompt is too long: 1 > 0"
            }
          }
        ]
      )

    assert {:error, %Error{type: :context_overflow} = error} =
             CoreChatModel.invoke(model, [Message.user("test")])

    assert error.details.status == 400
    assert error.details.error["type"] == "invalid_request_error"
    assert error.message =~ "prompt is too long"
  end

  test "model initializer supports explicit and inferred Anthropic identifiers" do
    assert {:ok, explicit} = Models.init_chat_model("anthropic:claude-haiku-4-5-20251001")
    assert explicit.__struct__ == ChatModel
    assert explicit.profile.provider == :anthropic

    assert {:ok, opus} = Models.init_chat_model("anthropic:claude-opus-4-8")
    assert opus.profile.max_input_tokens == 1_000_000
    assert opus.profile.max_output_tokens == 128_000
    assert opus.profile.extra.default_effort == :high

    assert {:ok, fable} = Models.init_chat_model("anthropic:claude-fable-5")
    assert fable.profile.max_input_tokens == 1_000_000
    assert fable.profile.max_output_tokens == 128_000
    assert fable.profile.extra.input_price_per_mtok == 10.00
    assert fable.profile.extra.output_price_per_mtok == 50.00
    assert fable.profile.extra.thinking_mode == :adaptive_only

    assert {:ok, mythos} = Models.init_chat_model("anthropic:claude-mythos-5")
    assert mythos.profile.status == :active
    assert mythos.profile.max_input_tokens == 1_000_000
    assert mythos.profile.max_output_tokens == 128_000
    assert mythos.profile.extra.input_price_per_mtok == 10.00

    assert {:ok, inferred} = Models.init_chat_model("claude-sonnet-4-6")
    assert inferred.__struct__ == ChatModel
    assert inferred.profile.structured_output
  end

  test "model initializer rejects deprecated and retired Anthropic identifiers" do
    assert {:error, deprecated} =
             Models.init_chat_model("anthropic:claude-sonnet-4-20250514")

    assert deprecated.type == :deprecated_model
    assert deprecated.details.provider == :anthropic
    assert deprecated.details.replacement == "claude-sonnet-4-6"
    assert deprecated.details.expected == "anthropic:claude-sonnet-4-6"
    assert deprecated.details.retirement_date == "2026-06-15"

    assert {:error, retired} =
             Models.init_chat_model("anthropic:claude-3-7-sonnet-20250219")

    assert retired.type == :deprecated_model
    assert retired.details.replacement == "claude-sonnet-4-6"
    assert retired.details.retirement_date == "2026-02-19"

    assert {:error, opus} =
             Models.init_chat_model("anthropic:claude-opus-4-20250514")

    assert opus.type == :deprecated_model
    assert opus.details.replacement == "claude-opus-4-8"
    assert opus.details.expected == "anthropic:claude-opus-4-8"
  end

  test "output parser extracts Anthropic tool_use blocks" do
    content = [
      %{"type" => "text", "text" => "checking"},
      %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup", "input" => %{"q" => "beam"}}
    ]

    assert OutputParsers.extract_tool_calls(content) == [
             %ToolCall{
               id: "toolu_1",
               provider_id: "toolu_1",
               call_id: "toolu_1",
               name: "lookup",
               args: %{"q" => "beam"}
             }
           ]
  end

  defp with_config(group, values, fun) do
    BeamWeaver.TestSupport.ConfigHelper.put_config(group, values)
    fun.()
  end
end
