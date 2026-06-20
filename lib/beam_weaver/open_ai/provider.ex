defmodule BeamWeaver.OpenAI.Provider do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def provider, do: :openai

  @impl true
  def profiles, do: ProfileRegistry.profiles(:openai)

  @impl true
  def chat_model(opts) do
    case Keyword.get(opts, :api, :responses) do
      :chat_completions -> {:ok, BeamWeaver.OpenAI.ChatCompletionsModel}
      "chat_completions" -> {:ok, BeamWeaver.OpenAI.ChatCompletionsModel}
      _other -> {:ok, BeamWeaver.OpenAI.ChatModel}
    end
  end

  @impl true
  def embedding_model(_opts), do: {:ok, BeamWeaver.OpenAI.EmbeddingModel}

  @impl true
  def profile(model), do: ProfileRegistry.fetch(:openai, model)

  @impl true
  def infer_provider?(model, :chat) when is_binary(model) do
    String.starts_with?(model, ["gpt-", "o1", "o3", "o4", "chatgpt"])
  end

  def infer_provider?("text-embedding" <> _rest, :embedding), do: true
  def infer_provider?(_model, _kind), do: false

  @impl true
  def default_model(:chat), do: "gpt-5.5"
  def default_model(:embedding), do: "text-embedding-3-small"
  def default_model(_kind), do: nil

  @impl true
  def capabilities, do: %{api_families: [:responses, :chat_completions, :embeddings]}
end
