defmodule BeamWeaver.ProviderConformanceTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.TestSupport.ProviderConformance, as: Fixtures

  describe "OpenAI Responses fixtures" do
    test "basic chat response normalizes text, usage, and metadata" do
      model = Fixtures.model(:openai, "basic_chat")

      assert {:ok, message} = ChatModel.invoke(model, [Message.user("ping")])

      Fixtures.assert_request!(:openai, "basic_chat")
      Fixtures.assert_message!(message, Fixtures.load!(:openai, "basic_chat")["expected"]["message"])
    end

    test "multiple tool calls preserve executable and provider call IDs" do
      model = Fixtures.model(:openai, "multiple_tool_calls")

      assert {:ok, message} =
               ChatModel.invoke(model, [Message.user("weather in Paris and Berlin")], tools: [Fixtures.weather_tool()])

      Fixtures.assert_request!(:openai, "multiple_tool_calls")
      Fixtures.assert_message!(message, Fixtures.load!(:openai, "multiple_tool_calls")["expected"]["message"])
    end

    test "tool-result messages are sent back in provider wire shape" do
      model = Fixtures.model(:openai, "tool_result_followup")

      messages = [
        Message.user("weather in Paris"),
        Message.assistant("",
          tool_calls: [
            Messages.tool_call(
              id: "call_weather_paris",
              provider_id: "fc_weather_paris",
              call_id: "call_weather_paris",
              name: "get_weather",
              args: %{"city" => "Paris"}
            )
          ]
        ),
        Message.tool(%{"temperature" => "18C", "condition" => "clear"},
          tool_call_id: "call_weather_paris",
          name: "get_weather"
        )
      ]

      assert {:ok, message} = ChatModel.invoke(model, messages, tools: [Fixtures.weather_tool()])

      Fixtures.assert_request!(:openai, "tool_result_followup")
      Fixtures.assert_message!(message, Fixtures.load!(:openai, "tool_result_followup")["expected"]["message"])
    end

    test "store false replay drops provider-only IDs and preserves replayable encrypted reasoning" do
      model = Fixtures.model(:openai, "store_false_replay_sanitization")

      messages = [
        Message.user("resume cached response"),
        Message.assistant([
          %{type: :text, id: "msg_cached", text: "cached answer"},
          %{type: :reasoning, id: "rs_plain", summary: []},
          %{type: :reasoning, id: "rs_enc", encrypted_content: "encrypted-reasoning", summary: []},
          %{type: :image_generation_call, id: "ig_empty", status: "completed"},
          %{type: :image_generation_call, id: "ig_result", result: "..."},
          %{
            type: :function_call,
            id: "fc_cached",
            call_id: "call_lookup",
            name: "lookup",
            arguments: %{"query" => "beam"}
          }
        ])
      ]

      assert {:ok, message} = ChatModel.invoke(model, messages, extra_body: %{store: false})

      Fixtures.assert_request!(:openai, "store_false_replay_sanitization")

      Fixtures.assert_message!(
        message,
        Fixtures.load!(:openai, "store_false_replay_sanitization")["expected"]["message"]
      )
    end

    test "provider-native structured output parses into metadata" do
      model = Fixtures.model(:openai, "provider_structured_success")

      assert {:ok, message} =
               ChatModel.invoke(model, [Message.user("answer as JSON")],
                 response_format: %{name: "answer_output", schema: Fixtures.answer_schema()}
               )

      Fixtures.assert_request!(:openai, "provider_structured_success")

      Fixtures.assert_message!(
        message,
        Fixtures.load!(:openai, "provider_structured_success")["expected"]["message"]
      )
    end
  end

  describe "OpenAI Chat Completions fixtures" do
    test "streaming response reconstructs tool-call chunks and detailed usage" do
      model = Fixtures.model(:openai_chat_completions, "streaming_tool_call")

      assert {:ok, message} =
               model.__struct__.stream_response(model, [Message.user("stream tools")],
                 stream_options: %{include_usage: true}
               )

      Fixtures.assert_request!(:openai_chat_completions, "streaming_tool_call")

      Fixtures.assert_message!(
        message,
        Fixtures.load!(:openai_chat_completions, "streaming_tool_call")["expected"]["message"]
      )
    end
  end

  describe "xAI Responses fixtures" do
    test "single tool call keeps xAI call_id mapping" do
      model = Fixtures.model(:xai, "single_tool_call")

      assert {:ok, message} =
               ChatModel.invoke(model, [Message.user("weather in Tokyo")], tools: [Fixtures.weather_tool()])

      Fixtures.assert_request!(:xai, "single_tool_call")
      Fixtures.assert_message!(message, Fixtures.load!(:xai, "single_tool_call")["expected"]["message"])
    end

    test "reasoning request shape omits unsupported stop sequences" do
      model = Fixtures.model(:xai, "reasoning_omits_stop")

      assert {:ok, message} = ChatModel.invoke(model, [Message.user("stop check")], stop: ["END"])

      Fixtures.assert_request!(:xai, "reasoning_omits_stop")
      Fixtures.assert_message!(message, Fixtures.load!(:xai, "reasoning_omits_stop")["expected"]["message"])
    end

    test "tool-strategy structured output appears as a normal provider tool call" do
      model = Fixtures.model(:xai, "tool_strategy_structured_success")
      [answer_tool] = StructuredOutput.setup_tools(Fixtures.structured_output(:tool))

      assert {:ok, message} =
               ChatModel.invoke(model, [Message.user("answer through the schema tool")], tools: [answer_tool])

      Fixtures.assert_request!(:xai, "tool_strategy_structured_success")

      Fixtures.assert_message!(
        message,
        Fixtures.load!(:xai, "tool_strategy_structured_success")["expected"]["message"]
      )
    end

    test "malformed structured JSON is a diagnostic parse error" do
      model = Fixtures.model(:xai, "malformed_structured_json")

      result =
        ChatModel.invoke(model, [Message.user("return malformed JSON")],
          response_format: %{name: "answer_output", schema: Fixtures.answer_schema()}
        )

      Fixtures.assert_request!(:xai, "malformed_structured_json")
      Fixtures.assert_error!(result, Fixtures.load!(:xai, "malformed_structured_json")["expected"]["error"])
    end

    test "provider HTTP errors normalize retryability and request metadata" do
      model = Fixtures.model(:xai, "http_invalid_schema")

      result =
        ChatModel.invoke(model, [Message.user("bad schema")],
          response_format: %{name: "answer_output", schema: Fixtures.answer_schema()}
        )

      Fixtures.assert_request!(:xai, "http_invalid_schema")
      Fixtures.assert_error!(result, Fixtures.load!(:xai, "http_invalid_schema")["expected"]["error"])
    end
  end

  describe "xAI Chat Completions fixtures" do
    test "streaming response reconstructs tool-call chunks and usage" do
      model = Fixtures.model(:xai_chat_completions, "streaming_tool_call")

      assert {:ok, message} =
               model.__struct__.stream_response(model, [Message.user("tools")])

      Fixtures.assert_request!(:xai_chat_completions, "streaming_tool_call")

      Fixtures.assert_message!(
        message,
        Fixtures.load!(:xai_chat_completions, "streaming_tool_call")["expected"]["message"]
      )
    end
  end

  describe "Google Gemini fixtures" do
    test "basic chat response normalizes Gemini usage metadata" do
      model = Fixtures.model(:google, "basic_chat")

      assert {:ok, message} = ChatModel.invoke(model, [Message.user("ping")])

      Fixtures.assert_request!(:google, "basic_chat")
      Fixtures.assert_message!(message, Fixtures.load!(:google, "basic_chat")["expected"]["message"])
    end

    test "function calls preserve Gemini thought signatures and IDs" do
      model = Fixtures.model(:google, "tool_call")

      assert {:ok, message} =
               ChatModel.invoke(model, [Message.user("weather in Paris")], tools: [Fixtures.weather_tool()])

      Fixtures.assert_request!(:google, "tool_call")
      Fixtures.assert_message!(message, Fixtures.load!(:google, "tool_call")["expected"]["message"])
    end

    test "provider-native structured output parses JSON response text" do
      model = Fixtures.model(:google, "provider_structured_success")

      assert {:ok, message} =
               ChatModel.invoke(model, [Message.user("answer as JSON")],
                 response_format: %{name: "answer_output", schema: Fixtures.answer_schema()}
               )

      Fixtures.assert_request!(:google, "provider_structured_success")

      Fixtures.assert_message!(
        message,
        Fixtures.load!(:google, "provider_structured_success")["expected"]["message"]
      )
    end

    test "truncated structured output returns provider diagnostics" do
      model = Fixtures.model(:google, "truncated_structured_output")

      result =
        ChatModel.invoke(model, [Message.user("answer as JSON")],
          response_format: %{name: "answer_output", schema: Fixtures.answer_schema()}
        )

      Fixtures.assert_request!(:google, "truncated_structured_output")
      Fixtures.assert_error!(result, Fixtures.load!(:google, "truncated_structured_output")["expected"]["error"])
    end
  end

  describe "Moonshot Kimi fixtures" do
    test "basic chat response normalizes text, reasoning, usage, and metadata" do
      model = Fixtures.model(:moonshot, "basic_chat")

      assert {:ok, message} = ChatModel.invoke(model, [Message.user("ping")])

      Fixtures.assert_request!(:moonshot, "basic_chat")
      Fixtures.assert_message!(message, Fixtures.load!(:moonshot, "basic_chat")["expected"]["message"])
    end

    test "single tool call preserves Kimi chat-completions IDs" do
      model = Fixtures.model(:moonshot, "single_tool_call")

      assert {:ok, message} =
               ChatModel.invoke(model, [Message.user("weather in Tokyo")], tools: [Fixtures.weather_tool()])

      Fixtures.assert_request!(:moonshot, "single_tool_call")
      Fixtures.assert_message!(message, Fixtures.load!(:moonshot, "single_tool_call")["expected"]["message"])
    end

    test "provider-native structured output parses Kimi JSON response" do
      model = Fixtures.model(:moonshot, "provider_structured_success")

      assert {:ok, message} =
               ChatModel.invoke(model, [Message.user("answer as JSON")],
                 response_format: %{name: "answer_output", schema: Fixtures.answer_schema()}
               )

      Fixtures.assert_request!(:moonshot, "provider_structured_success")

      Fixtures.assert_message!(
        message,
        Fixtures.load!(:moonshot, "provider_structured_success")["expected"]["message"]
      )
    end

    test "streaming response captures final usage metadata" do
      model = Fixtures.model(:moonshot, "streaming_usage")

      assert {:ok, message} = model.__struct__.stream_response(model, [Message.user("stream pong")])

      Fixtures.assert_request!(:moonshot, "streaming_usage")
      Fixtures.assert_message!(message, Fixtures.load!(:moonshot, "streaming_usage")["expected"]["message"])
    end

    test "provider HTTP errors normalize provider-specific error types" do
      model = Fixtures.model(:moonshot, "http_quota_error")

      result = ChatModel.invoke(model, [Message.user("quota")])

      Fixtures.assert_request!(:moonshot, "http_quota_error")
      Fixtures.assert_error!(result, Fixtures.load!(:moonshot, "http_quota_error")["expected"]["error"])
    end
  end

  describe "Z.ai GLM fixtures" do
    test "basic chat response normalizes text, reasoning, usage, and metadata" do
      model = Fixtures.model(:zai, "basic_chat")

      assert {:ok, message} = ChatModel.invoke(model, [Message.user("ping")])

      Fixtures.assert_request!(:zai, "basic_chat")
      Fixtures.assert_message!(message, Fixtures.load!(:zai, "basic_chat")["expected"]["message"])
    end

    test "provider-native JSON mode parses structured output" do
      model = Fixtures.model(:zai, "provider_structured_success")

      assert {:ok, message} =
               ChatModel.invoke(model, [Message.user("answer as JSON")],
                 response_format: %{name: "answer_output", schema: Fixtures.answer_schema()}
               )

      Fixtures.assert_request!(:zai, "provider_structured_success")

      Fixtures.assert_message!(
        message,
        Fixtures.load!(:zai, "provider_structured_success")["expected"]["message"]
      )
    end

    test "single tool call preserves GLM chat-completions IDs" do
      model = Fixtures.model(:zai, "single_tool_call")

      assert {:ok, message} =
               ChatModel.invoke(model, [Message.user("weather in Tokyo")], tools: [Fixtures.weather_tool()])

      Fixtures.assert_request!(:zai, "single_tool_call")
      Fixtures.assert_message!(message, Fixtures.load!(:zai, "single_tool_call")["expected"]["message"])
    end

    test "streaming response captures final usage metadata" do
      model = Fixtures.model(:zai, "streaming_usage")

      assert {:ok, message} = model.__struct__.stream_response(model, [Message.user("stream pong")])

      Fixtures.assert_request!(:zai, "streaming_usage")
      Fixtures.assert_message!(message, Fixtures.load!(:zai, "streaming_usage")["expected"]["message"])
    end

    test "reasoning-only stream truncation is surfaced as length" do
      model = Fixtures.model(:zai, "reasoning_stream_truncated")

      assert {:ok, message} =
               model.__struct__.stream_response(
                 model,
                 [Message.user("think until length")],
                 thinking: %{type: "enabled"},
                 reasoning_effort: "low",
                 max_tokens: 32
               )

      Fixtures.assert_request!(:zai, "reasoning_stream_truncated")
      Fixtures.assert_message!(message, Fixtures.load!(:zai, "reasoning_stream_truncated")["expected"]["message"])
    end

    test "streamed tool-call argument chunks merge by index" do
      model = Fixtures.model(:zai, "streaming_tool_call")

      assert {:ok, message} =
               model.__struct__.stream_response(
                 model,
                 [Message.user("stream tool")],
                 tools: [Fixtures.weather_tool()],
                 tool_choice: "auto",
                 tool_stream: true
               )

      Fixtures.assert_request!(:zai, "streaming_tool_call")
      Fixtures.assert_message!(message, Fixtures.load!(:zai, "streaming_tool_call")["expected"]["message"])
    end

    test "provider HTTP errors normalize retryability and log IDs" do
      model = Fixtures.model(:zai, "http_rate_limit_error")

      result = ChatModel.invoke(model, [Message.user("rate limit")])

      Fixtures.assert_request!(:zai, "http_rate_limit_error")
      Fixtures.assert_error!(result, Fixtures.load!(:zai, "http_rate_limit_error")["expected"]["error"])
    end
  end

  describe "structured-output strategy policy fixtures" do
    test "fallback fixture records provider profile decision when native output is unsafe" do
      fixture = Fixtures.load!(:xai, "structured_fallback_when_tools_active")
      model = Fixtures.model(:xai, "structured_fallback_when_tools_active")

      {strategy, policy} =
        StructuredOutput.effective_strategy_info(
          Fixtures.structured_output(:provider),
          model,
          [Fixtures.weather_tool()]
        )

      assert %StructuredOutput.ToolStrategy{} = strategy

      Fixtures.assert_matches_expected!(
        policy,
        fixture["expected"]["policy"]
      )
    end
  end
end
