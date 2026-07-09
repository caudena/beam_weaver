defmodule BeamWeaver.XAI.Provider do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def provider, do: :xai

  @impl true
  def profiles, do: ProfileRegistry.profiles(:xai)

  @impl true
  def chat_model(opts) do
    case Keyword.get(opts, :api, :responses) do
      :chat_completions -> {:ok, BeamWeaver.XAI.ChatCompletionsModel}
      "chat_completions" -> {:ok, BeamWeaver.XAI.ChatCompletionsModel}
      _other -> {:ok, BeamWeaver.XAI.ChatModel}
    end
  end

  @impl true
  def embedding_model(_opts), do: {:ok, BeamWeaver.XAI.EmbeddingModel}

  @impl true
  def profile(model), do: ProfileRegistry.fetch(:xai, model)

  @impl true
  def infer_provider?("grok-" <> _rest, :chat), do: true
  def infer_provider?(_model, _kind), do: false

  @impl true
  def default_model(:chat), do: "grok-4.5"
  def default_model(:embedding), do: "v1"
  def default_model(_kind), do: nil

  @impl true
  def capabilities,
    do: %{api_families: [:responses, :chat_completions, :embeddings], openai_compatible: true}
end
