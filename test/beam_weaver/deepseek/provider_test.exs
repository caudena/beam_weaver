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

  test "initializer defaults to Chat and accepts supported V4 models on Responses" do
    assert {:ok, %ChatModel{model: "deepseek-v4-flash"}} =
             Models.init_chat_model("deepseek:deepseek-v4-flash")

    for model <- ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp", "deepseek-v4-pro"],
        api <- [:responses, "responses"] do
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
      refute Map.has_key?(error.details, :replacement)
    end
  end

  test "DeepAgents resolver identifies both DeepSeek API models" do
    assert {:ok, chat} = ModelResolver.resolve_model("deepseek:deepseek-v4-flash")
    assert ModelResolver.get_model_provider(chat) == "deepseek"
    assert ModelResolver.get_model_identifier(chat) == "deepseek-v4-flash"

    for model <- ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp", "deepseek-v4-pro"] do
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
