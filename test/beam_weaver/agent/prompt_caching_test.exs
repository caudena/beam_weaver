defmodule BeamWeaver.Agent.PromptCachingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.PromptCaching
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Runtime
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.PromptCache

  test "prompt cache keys keep full scope and hash stable prompt content" do
    key = PromptCache.key("support-agent-fresh-long-scope", "xai:grok-4.3", "static policy", version: "v2")

    assert key =~ "bwpc:v2:support-agent-fresh-long-scope:xai-grok-4.3:"
    assert key == PromptCache.key("support-agent-fresh-long-scope", "xai:grok-4.3", "static policy", version: "v2")
    refute key == PromptCache.key("support-agent-fresh-long-scope-2", "xai:grok-4.3", "static policy", version: "v2")
  end

  test "prompt cache helpers accept atom option keys only" do
    assert PromptCache.key(%{scope: "report", provider_model: "xai:grok-4.3", static_prompt: "static", version: "v2"}) =~
             "bwpc:v2:report:xai-grok-4.3:"

    assert PromptCache.key(%{
             "scope" => "report",
             "provider_model" => "xai:grok-4.3",
             "static_prompt" => "static",
             "version" => "v2"
           }) =~ "bwpc:v1:default:unknown:"
  end

  test "prompt caching preserves Anthropic system prompt cache control" do
    request =
      ModelRequest.new(
        model: BeamWeaver.Anthropic.ChatModel.new(),
        system_prompt: "base"
      )

    assert %ModelRequest{system_message: %Message{content: [block]}, model_opts: []} =
             PromptCaching.wrap_model_call(PromptCaching.new(), request, & &1)

    assert block.text == "base"
    assert block.cache_control == %{type: :ephemeral}
  end

  test "prompt caching middleware accepts atom option keys only" do
    assert %PromptCaching{helper: %{cache_control: %{type: :ephemeral}}, scope: "report", version: "v2"} =
             PromptCaching.new(cache_control: %{type: :ephemeral}, scope: "report", version: "v2")

    assert %PromptCaching{helper: %{cache_control: %{type: :ephemeral}}, scope: nil, version: "v1"} =
             PromptCaching.new(%{
               "cache_control" => %{type: :ephemeral},
               "scope" => "report",
               "version" => "v2"
             })
  end

  test "prompt caching injects provider cache opts without overriding explicit opts" do
    middleware = PromptCaching.new(scope: "ai_report", version: "v9")
    runtime = %Runtime{graph_name: "ReportGraph", node: "model"}

    xai_request =
      ModelRequest.new(
        model: BeamWeaver.XAI.ChatModel.new(model: "grok-4.3"),
        system_prompt: "static",
        runtime: runtime
      )

    assert %ModelRequest{model_opts: xai_opts} = PromptCaching.wrap_model_call(middleware, xai_request, & &1)

    xai_key = Keyword.fetch!(xai_opts, :prompt_cache_key)
    assert xai_key =~ "bwpc:v9:ai_report:xai-grok-4.3:"
    assert Keyword.fetch!(xai_opts, :x_grok_conv_id) == xai_key

    explicit_request =
      ModelRequest.new(
        model: BeamWeaver.XAI.ChatModel.new(model: "grok-4.3"),
        system_prompt: "static",
        runtime: runtime,
        model_opts: [prompt_cache_key: "explicit-body", x_grok_conv_id: "explicit-header"]
      )

    assert %ModelRequest{model_opts: explicit_opts} =
             PromptCaching.wrap_model_call(middleware, explicit_request, & &1)

    assert Keyword.fetch!(explicit_opts, :prompt_cache_key) == "explicit-body"
    assert Keyword.fetch!(explicit_opts, :x_grok_conv_id) == "explicit-header"
  end

  test "prompt caching maps supported providers to their provider-specific knobs" do
    middleware = PromptCaching.new(scope: "scope")

    assert_cache_opts(middleware, BeamWeaver.OpenAI.ChatModel.new(model: "gpt-5.4-mini"), [:prompt_cache_key])

    assert_cache_opts(middleware, BeamWeaver.OpenAI.ChatCompletionsModel.new(model: "gpt-5.4-mini"), [:prompt_cache_key])

    assert_cache_opts(middleware, BeamWeaver.XAI.ChatModel.new(model: "grok-4.3"), [:prompt_cache_key, :x_grok_conv_id])
    assert_cache_opts(middleware, BeamWeaver.XAI.ChatCompletionsModel.new(model: "grok-4.3"), [:x_grok_conv_id])
    assert_cache_opts(middleware, BeamWeaver.Moonshot.ChatModel.new(model: "kimi-k2.6"), [:prompt_cache_key])

    fake_request = ModelRequest.new(model: %FakeChatModel{}, system_prompt: "static", model_opts: [temperature: 0.2])

    assert %ModelRequest{model_opts: [temperature: 0.2]} =
             PromptCaching.wrap_model_call(middleware, fake_request, & &1)
  end

  defp assert_cache_opts(middleware, model, expected_keys) do
    request = ModelRequest.new(model: model, system_prompt: "static", runtime: %Runtime{graph_name: "DefaultGraph"})

    assert %ModelRequest{model_opts: opts} = PromptCaching.wrap_model_call(middleware, request, & &1)

    for key <- expected_keys do
      assert Keyword.fetch!(opts, key) =~ "bwpc:v1:scope:"
    end

    unexpected = [:prompt_cache_key, :x_grok_conv_id] -- expected_keys

    for key <- unexpected do
      refute Keyword.has_key?(opts, key)
    end
  end
end
