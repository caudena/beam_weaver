defmodule BeamWeaver.DeepSeek.ProviderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.ModelResolver
  alias BeamWeaver.DeepSeek.ChatModel
  alias BeamWeaver.DeepSeek.ResponsesModel
  alias BeamWeaver.Models
  alias BeamWeaver.Models.ProfileRegistry

  test "public facade exposes default and explicit API constructors" do
    assert %ChatModel{} = BeamWeaver.DeepSeek.chat_model()
    assert %ChatModel{} = BeamWeaver.DeepSeek.chat_completions_model()
    assert %ResponsesModel{} = BeamWeaver.DeepSeek.responses_model()
  end

  test "profiles expose current V4 limits, APIs, and canonical prices" do
    assert {:ok, flash} = ProfileRegistry.fetch(:deepseek, "deepseek-v4-flash")
    assert flash.max_input_tokens == 1_048_576
    assert flash.max_output_tokens == 393_216
    assert flash.chat_completions_api
    assert flash.responses_api
    assert flash.extra.input_price_per_mtok == 0.14
    assert flash.extra.cached_input_price_per_mtok == 0.0028
    assert flash.extra.output_price_per_mtok == 0.28
    assert flash.extra.reasoning_efforts == [:low, :high, :max]

    assert flash.extra.compatibility_reasoning_efforts == %{
             minimal: :low,
             medium: :high,
             xhigh: :high
           }

    assert {:ok, pro} = ProfileRegistry.fetch(:deepseek, "deepseek-v4-pro")
    assert pro.chat_completions_api
    assert pro.responses_api
    assert pro.extra.input_price_per_mtok == 0.435
    assert pro.extra.cached_input_price_per_mtok == 0.003625
    assert pro.extra.output_price_per_mtok == 0.87
    assert pro.extra.reasoning_efforts == flash.extra.reasoning_efforts

    assert pro.extra.compatibility_reasoning_efforts ==
             flash.extra.compatibility_reasoning_efforts
  end

  test "initializer defaults to Chat and accepts both V4 models on Responses" do
    assert {:ok, %ChatModel{model: "deepseek-v4-flash"}} =
             Models.init_chat_model("deepseek:deepseek-v4-flash")

    for model <- ["deepseek-v4-flash", "deepseek-v4-pro"], api <- [:responses, "responses"] do
      assert {:ok, %ResponsesModel{model: ^model}} =
               Models.init_chat_model("deepseek:" <> model, api: api)
    end

    for api <- [:chat, :chat_completions, "chat", "chat_completions"] do
      assert {:ok, %ChatModel{}} =
               Models.init_chat_model("deepseek:deepseek-v4-pro", api: api)
    end

    assert {:error, error} =
             Models.init_chat_model("deepseek:deepseek-v4-flash", api: :unknown)

    assert error.type == :invalid_provider_option
  end

  test "bare and retired model identifiers fail without ambiguous aliases" do
    assert {:error, error} = Models.init_chat_model("deepseek-v4-flash")
    assert error.type == :invalid_model
    assert error.details.expected == "deepseek:deepseek-v4-flash"

    for retired <- ["deepseek-chat", "deepseek-reasoner"] do
      assert {:error, error} = Models.init_chat_model("deepseek:" <> retired)
      assert error.type == :deprecated_model
      assert error.details.supported == ["deepseek-v4-flash", "deepseek-v4-pro"]
      refute Map.has_key?(error.details, :replacement)
    end
  end

  test "DeepAgents resolver identifies both DeepSeek API models" do
    assert {:ok, chat} = ModelResolver.resolve_model("deepseek:deepseek-v4-flash")
    assert ModelResolver.get_model_provider(chat) == "deepseek"
    assert ModelResolver.get_model_identifier(chat) == "deepseek-v4-flash"

    for model <- ["deepseek-v4-flash", "deepseek-v4-pro"] do
      assert {:ok, responses} =
               ModelResolver.resolve_model("deepseek:" <> model, api: :responses)

      assert ModelResolver.get_model_provider(responses) == "deepseek"
      assert ModelResolver.get_model_identifier(responses) == model
    end
  end

  test "high-level structs redact credentials" do
    models = [
      {ChatModel.new(api_key: "chat-secret"), "chat-secret"},
      {ResponsesModel.new(api_key: "responses-secret"), "responses-secret"}
    ]

    for {model, secret} <- models do
      inspected = inspect(model, limit: :infinity)

      refute inspected =~ secret
      assert inspected =~ ~s(api_key: "**REDACTED**")
    end
  end
end
