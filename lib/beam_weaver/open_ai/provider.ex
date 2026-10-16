defmodule BeamWeaver.OpenAI.Provider do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.OpenAI.RequestMetadata

  @impl true
  def provider, do: :openai

  @impl true
  def profiles, do: ProfileRegistry.profiles(:openai)

  # A model's `metadata` fails when the model is created, as it would on
  # every call.
  @impl true
  def chat_model(opts) do
    with {:ok, module} <- chat_module(opts),
         :ok <- RequestMetadata.validate(Keyword.get(opts, :metadata), Keyword.get(opts, :model)),
         do: {:ok, module}
  end

  defp chat_module(opts) do
    case Keyword.get(opts, :api) || :responses do
      api when api in [:responses, "responses"] ->
        {:ok, BeamWeaver.OpenAI.ChatModel}

      api when api in [:chat_completions, "chat_completions"] ->
        {:ok, BeamWeaver.OpenAI.ChatCompletionsModel}

      api ->
        {:error,
         BeamWeaver.Core.Error.new(:invalid_provider_option, "unsupported OpenAI API selection", %{
           provider: :openai,
           option: :api,
           value: api,
           supported: [:responses, :chat_completions]
         })}
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
