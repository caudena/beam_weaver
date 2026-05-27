defmodule BeamWeaver.Anthropic.Provider do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def provider, do: :anthropic

  @impl true
  def profiles, do: ProfileRegistry.profiles(:anthropic)

  @impl true
  def chat_model(_opts), do: {:ok, BeamWeaver.Anthropic.ChatModel}

  @impl true
  def embedding_model(_opts) do
    {:error,
     Error.new(:unsupported_provider, "Anthropic embeddings are not supported", %{
       provider: :anthropic
     })}
  end

  @impl true
  def profile(model), do: ProfileRegistry.fetch(:anthropic, model)

  @impl true
  def infer_provider?("claude-" <> _rest, :chat), do: true
  def infer_provider?(_model, _kind), do: false

  @impl true
  def default_model(:chat), do: "claude-haiku-4-5-20251001"
  def default_model(_kind), do: nil

  @impl true
  def capabilities, do: %{api_families: [:messages]}
end
