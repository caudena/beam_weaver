defmodule BeamWeaver.Anthropic.AdaptiveThinkingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.ChatModel
  alias BeamWeaver.Anthropic.ChatModel.RequestBuilder
  alias BeamWeaver.Anthropic.Tools
  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message

  test "Haiku accepts forced tools with adaptive thinking and disabled thinking through high effort" do
    model = ChatModel.new(model: "claude-haiku-5-5")
    messages = [Message.user("Look this up")]

    for builder <- [&ChatModel.request_body/3, &RequestBuilder.count_tokens_body/3] do
      for thinking <- [nil, %{type: :adaptive}, %{"type" => "adaptive"}] do
        assert {:ok, body} = builder.(model, messages, thinking: thinking, tool_choice: :any)
        assert body["tool_choice"] == %{"type" => "any"}
        assert {:ok, named} = builder.(model, messages, thinking: thinking, tool_choice: "lookup")
        assert named["tool_choice"] == %{"type" => "tool", "name" => "lookup"}
      end

      assert {:ok, body} = builder.(model, messages, thinking: %{type: :disabled}, effort: :high)
      assert body["thinking"] == %{"type" => "disabled"}

      for opts <- [
            [thinking: %{type: :enabled, budget_tokens: 1_024}],
            [thinking: %{type: :between_tools}],
            [thinking: %{type: :disabled}, effort: :xhigh],
            [thinking: %{"type" => "disabled"}, output_config: %{"effort" => "max"}]
          ] do
        assert {:error, error} = builder.(model, messages, opts)
        assert error.type == :unsupported_model_param
        assert :thinking in error.details.params
      end
    end
  end

  test "Sonnet accepts between_tools through high effort and rejects forced tools" do
    model = ChatModel.new(model: "claude-sonnet-5-5")
    messages = [Message.user("Look this up")]

    for builder <- [&ChatModel.request_body/3, &RequestBuilder.count_tokens_body/3] do
      for effort <- [:low, :medium, :high] do
        assert {:ok, body} = builder.(model, messages, thinking: %{type: :between_tools}, effort: effort)
        assert body["thinking"] == %{"type" => "between_tools"}
        assert body["output_config"]["effort"] == Atom.to_string(effort)
      end

      for opts <- [
            [thinking: %{type: :disabled}],
            [thinking: %{type: :enabled, budget_tokens: 1_024}],
            [thinking: %{type: :between_tools}, effort: :xhigh],
            [thinking: %{"type" => "between_tools"}, output_config: %{"effort" => "max"}],
            [tool_choice: :any],
            [tool_choice: "lookup"]
          ] do
        assert {:error, error} = builder.(model, messages, opts)
        assert error.type == :unsupported_model_param
      end
    end
  end

  test "new models reject unsupported sampling, prefills, and legacy computer tools before transport" do
    for id <- ["claude-haiku-5-5", "claude-sonnet-5-5"] do
      model = ChatModel.new(model: id, transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport)
      messages = [Message.user("hello")]

      for opts <- [[temperature: 0.2], [top_p: 1], [top_p: 0.98], [top_k: 1], [temperature: 1, top_p: 0.99]] do
        assert {:error, error} = CoreChatModel.invoke(model, messages, opts)
        assert error.type == :unsupported_model_param
      end

      assert {:ok, _} = ChatModel.request_body(model, messages, temperature: 1)
      assert {:ok, _} = ChatModel.request_body(model, messages, top_p: 0.99)

      for builder <- [&ChatModel.request_body/3, &RequestBuilder.count_tokens_body/3] do
        assert {:error, prefill} = builder.(model, messages ++ [Message.assistant("Start")], [])
        assert prefill.type == :invalid_message
        assert {:error, computer} = builder.(model, messages, tools: [Tools.computer()])
        assert computer.type == :unsupported_feature
        assert {:ok, _} = builder.(model, messages, tools: [Tools.computer_toolset(), Tools.browser_toolset()])
      end
    end

    refute_received {:fake_transport_request, _}
  end

  test "Haiku rejects server fallback and Priority Tier, while Sonnet permits fallback" do
    haiku = ChatModel.new(model: "claude-haiku-5-5")
    messages = [Message.user("hello")]

    for opts <- [[fallbacks: :default], [fallbacks: ["claude-sonnet-5-5"]], [service_tier: :priority]] do
      assert {:error, error} = ChatModel.request_body(haiku, messages, opts)
      assert error.type == :unsupported_model_param
    end

    sonnet = ChatModel.new(model: "claude-sonnet-5-5")
    assert {:ok, body} = ChatModel.request_body(sonnet, messages, fallbacks: :default)
    assert body["fallbacks"] == "default"
    assert "server-side-fallback-2026-07-01" in body["betas"]
  end

  test "new model responses preserve omitted thinking, toolset replay, and current diagnostics" do
    for id <- ["claude-haiku-5-5", "claude-sonnet-5-5"] do
      model =
        ChatModel.new(
          model: id,
          api_key: "test-key",
          transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
          transport_opts: [
            parent: self(),
            body: %{
              "id" => "msg_current",
              "type" => "message",
              "role" => "assistant",
              "model" => id,
              "content" => [
                %{"type" => "thinking", "thinking" => "", "signature" => "signed-reasoning"},
                %{
                  "type" => "tool_use",
                  "id" => "toolu_browser",
                  "name" => "navigate",
                  "toolset_name" => "browser",
                  "input" => %{"url" => "https://example.com"}
                }
              ],
              "stop_reason" => "tool_use",
              "diagnostics" => %{"cache_miss_reason" => %{"type" => "model_changed"}},
              "usage" => %{"input_tokens" => 12, "output_tokens" => 8}
            }
          ]
        )

      assert {:ok, response} = CoreChatModel.invoke(model, [Message.user("Open the page")])
      assert response.usage_metadata.input_tokens == 12
      assert response.response_metadata.diagnostics["cache_miss_reason"]["type"] == "model_changed"
      assert [call] = response.tool_calls
      assert call.name == "navigate"
      history = [Message.user("Open the page"), response, Message.user("Continue")]
      assert {:ok, body} = ChatModel.request_body(model, history)

      assert Enum.at(body["messages"], 1)["content"] == [
               %{"type" => "thinking", "thinking" => "", "signature" => "signed-reasoning"},
               %{
                 "type" => "tool_use",
                 "id" => "toolu_browser",
                 "name" => "navigate",
                 "toolset_name" => "browser",
                 "input" => %{"url" => "https://example.com"}
               }
             ]

      assert_received {:fake_transport_request, request}
      assert request.url == "https://api.anthropic.com/v1/messages"
      assert {"anthropic-version", "2023-06-01"} in request.headers
    end
  end

  test "thinking display updates and prefix controls infer their beta headers" do
    model = ChatModel.new(model: "claude-sonnet-5-5")

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("hello")],
               thinking: %{type: :adaptive, display: :updates, block_binding: %{prefix_mismatch_behavior: :drop_block}}
             )

    assert "thinking-display-updates-2026-08-18" in body["betas"]
    assert "thinking-binding-controls-2026-08-01" in body["betas"]
  end

  test "reduced thinking cannot change per-turn effort or use adaptive prefix controls" do
    for {id, reduced} <- [{"claude-haiku-5-5", :disabled}, {"claude-sonnet-5-5", :between_tools}] do
      model = ChatModel.new(model: id)
      messages = [Message.user("hello"), Message.system("Continue", metadata: %{output_config: %{effort: :low}})]

      for builder <- [&ChatModel.request_body/3, &RequestBuilder.count_tokens_body/3] do
        assert {:error, error} = builder.(model, messages, thinking: %{type: reduced}, effort: :high)
        assert error.type == :unsupported_model_param
        assert {:ok, _} = builder.(model, messages, thinking: %{type: reduced}, effort: :low)
        assert {:ok, _} = builder.(model, messages, thinking: %{type: :adaptive}, effort: :high)

        assert {:error, _} =
                 builder.(model, [Message.user("hello")],
                   thinking: %{type: reduced, block_binding: %{prefix_mismatch_behavior: :drop_block}}
                 )
      end
    end
  end

  test "Sonnet rejects the advisor pairings removed in 5.5" do
    model = ChatModel.new(model: "claude-sonnet-5-5")

    for builder <- [&ChatModel.request_body/3, &RequestBuilder.count_tokens_body/3] do
      for advisor <- ["claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-5"] do
        assert {:error, error} = builder.(model, [Message.user("hello")], tools: [Tools.advisor(model: advisor)])
        assert error.type == :unsupported_feature
        assert error.details.unsupported_advisor_models == [advisor]
      end

      assert {:ok, _} = builder.(model, [Message.user("hello")], tools: [Tools.advisor(model: "claude-opus-5-5")])
    end
  end

  test "Haiku streaming reconstructs empty signed thinking and fragmented tool inputs" do
    body = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_stream55","type":"message","role":"assistant","model":"claude-haiku-5-5","content":[],"usage":{"input_tokens":2}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"stream-signature"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_stream55","name":"navigate","toolset_name":"browser","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\\"url\\\":\\\"https://example.com\\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":8}}

    event: message_stop
    data: {"type":"message_stop"}
    """

    model =
      ChatModel.new(
        model: "claude-haiku-5-5",
        api_key: "test-key",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [body: body, headers: [{"content-type", "text/event-stream"}]]
      )

    assert {:ok, response} = ChatModel.stream_response(model, [Message.user("Open the page")])
    assert [call] = response.tool_calls
    assert call.args == %{"url" => "https://example.com"}
    assert response.status == "tool_use"
    assert response.usage_metadata.output_tokens == 8

    assert {:ok, replay} =
             ChatModel.request_body(model, [Message.user("Open the page"), response, Message.user("Continue")])

    assert [thinking, tool] = Enum.at(replay["messages"], 1)["content"]
    assert thinking == %{"type" => "thinking", "thinking" => "", "signature" => "stream-signature"}
    assert tool["toolset_name"] == "browser"
  end
end
