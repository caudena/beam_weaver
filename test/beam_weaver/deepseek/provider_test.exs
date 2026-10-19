defmodule BeamWeaver.DeepSeek.ProviderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.ModelResolver
  alias BeamWeaver.DeepSeek.ChatModel
  alias BeamWeaver.DeepSeek.ResponsesModel
  alias BeamWeaver.Models

  test "public facade exposes default and explicit API constructors" do
    assert %ChatModel{} = BeamWeaver.DeepSeek.chat_model()
    assert %ChatModel{} = BeamWeaver.DeepSeek.chat_completions_model()
    assert %ResponsesModel{} = BeamWeaver.DeepSeek.responses_model()
  end

  test "initializer selects APIs independently of catalog entries" do
    opts = [profile: %{provider: :deepseek, id: "fixture"}]
    id = "deepseek:fixture"
    assert {:ok, %ChatModel{model: "fixture"}} = Models.init_chat_model(id, opts)

    for api <- [:responses, "responses"] do
      assert {:ok, %ResponsesModel{model: "fixture"}} = Models.init_chat_model(id, Keyword.put(opts, :api, api))
    end

    for api <- [:chat, :chat_completions, "chat", "chat_completions"] do
      assert {:ok, %ChatModel{}} = Models.init_chat_model(id, Keyword.put(opts, :api, api))
    end

    assert {:error, %{type: :invalid_provider_option}} = Models.init_chat_model(id, api: :unknown)
  end

  test "DeepAgents resolver identifies both DeepSeek API adapters" do
    for api <- [:chat_completions, :responses] do
      assert {:ok, model} =
               ModelResolver.resolve_model("deepseek:fixture",
                 api: api,
                 profile: %{provider: :deepseek, id: "fixture"}
               )

      assert BeamWeaver.Models.Identity.provider(model) == "deepseek"
      assert BeamWeaver.Models.Identity.identifier(model) == "fixture"
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
