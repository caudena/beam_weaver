defmodule BeamWeaver.Anthropic.Models55Test do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.ChatModel
  alias BeamWeaver.Anthropic.ChatModel.RequestBuilder
  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Anthropic.Tools
  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.Models.UsageCost

  test "new Claude models initialize and expose checked-in capabilities" do
    for {id, effort, released} <- [
          {"claude-haiku-5-5", :medium, "2026-10-07"},
          {"claude-sonnet-5-5", :high, "2026-09-28"}
        ] do
      assert {:ok, model} = Models.init_chat_model("anthropic:" <> id)
      assert {:ok, inferred} = Models.init_chat_model(id)
      assert inferred.profile == model.profile
      assert {:ok, profile} = ProfileRegistry.fetch(:anthropic, id)
      assert profile == model.profile
      assert profile in ProfileRegistry.all()
      assert model.max_tokens == 128_000
      assert profile.max_input_tokens == 1_000_000
      assert profile.context_limit_kind == :shared_context
      assert profile.max_context_tokens == 1_000_000
      assert profile.max_output_tokens == 128_000
      assert profile.release_date == released
      assert profile.extra.default_effort == effort
      assert profile.extra.effort_levels == [:low, :medium, :high, :xhigh, :max]
      assert profile.extra.prompt_cache_min_tokens == 512
      assert profile.extra.batch_max_output_tokens == 300_000
      assert profile.extra.thinking_display_default == :omitted
      assert profile.image_inputs and profile.pdf_inputs and profile.reasoning_output
      assert profile.tool_calling and profile.parallel_tool_calls and profile.streaming
      assert profile.structured_output and profile.structured_output_with_tools
      refute profile.temperature
    end
  end

  test "Haiku prices all input and output at the tier selected by total prompt length" do
    profile = ChatModel.new(model: "claude-haiku-5-5").profile
    assert profile.extra.batch_input_price_per_mtok == 0.05
    assert profile.extra.batch_output_price_per_mtok == 0.25
    assert profile.extra.long_context_pricing.batch_input_price_per_mtok == 0.25
    assert profile.extra.long_context_pricing.batch_output_price_per_mtok == 1.25

    at_boundary = UsageCost.calculate(profile, %{input_tokens: 100_000, output_tokens: 1_000})
    above_boundary = UsageCost.calculate(profile, %{input_tokens: 100_001, output_tokens: 1_000})
    assert_in_delta at_boundary.total_cost, 0.0105, 1.0e-12
    assert_in_delta above_boundary.total_cost, 0.0525005, 1.0e-12

    # Anthropic reports uncached input separately. Normalization includes the
    # cache reads and both write TTLs in the total used to select the tier.
    usage =
      Messages.usage_metadata(%{
        "input_tokens" => 1,
        "cache_read_input_tokens" => 90_000,
        "cache_creation_input_tokens" => 10_000,
        "cache_creation" => %{"ephemeral_5m_input_tokens" => 6_000, "ephemeral_1h_input_tokens" => 4_000},
        "output_tokens" => 1_000
      })

    assert usage.input_tokens == 100_001
    costs = UsageCost.calculate(profile, usage)
    assert_in_delta costs.input_cost_details.uncached, 0.0000005, 1.0e-12
    assert_in_delta costs.input_cost_details.cache_read, 0.0045, 1.0e-12
    assert_in_delta costs.input_cost_details.cache_write_5m_tokens, 0.00375, 1.0e-12
    assert_in_delta costs.input_cost_details.cache_write_1h_tokens, 0.004, 1.0e-12
    assert_in_delta costs.output_cost, 0.0025, 1.0e-12
    assert_in_delta costs.total_cost, 0.0147505, 1.0e-12

    boundary_costs = UsageCost.calculate(profile, %{usage | input_tokens: 100_000})
    assert_in_delta boundary_costs.total_cost, 0.00295, 1.0e-12

    serialized = BeamWeaver.Provider.Options.stringify_keys(profile.extra)
    assert UsageCost.calculate(serialized, usage) == costs
    # Output length never selects the long-prompt tier.
    assert UsageCost.calculate(profile, %{input_tokens: 1, output_tokens: 128_000}).output_cost == 0.064
  end

  test "Sonnet uses the October 7 cache-read reduction and retains dated pricing" do
    profile = ChatModel.new(model: "claude-sonnet-5-5").profile
    usage = %{input_tokens: 1_000_000, output_tokens: 1_000, input_token_details: %{cache_read: 1_000_000}}
    assert_in_delta UsageCost.calculate(profile, usage).total_cost, 0.11, 1.0e-12
    assert_in_delta UsageCost.calculate(profile, usage, at: ~U[2026-10-06 12:00:00Z]).total_cost, 0.21, 1.0e-12
    assert_in_delta UsageCost.calculate(profile, usage, at: ~U[2026-10-08 12:00:00Z]).total_cost, 0.11, 1.0e-12
  end

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
