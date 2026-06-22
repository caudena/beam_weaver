defmodule BeamWeaver.ZAI.Provider do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def provider, do: :zai

  @impl true
  def profiles, do: ProfileRegistry.profiles(:zai)

  @impl true
  def chat_model(_opts), do: {:ok, BeamWeaver.ZAI.ChatModel}

  @impl true
  def profile(model), do: ProfileRegistry.fetch(:zai, model)

  @impl true
  def infer_provider?(_model, _kind), do: false

  @impl true
  def default_model(:chat), do: "glm-5.2"
  def default_model(_kind), do: nil

  @impl true
  def capabilities,
    do: %{api_families: [:chat_completions], openai_compatible: true}
end
