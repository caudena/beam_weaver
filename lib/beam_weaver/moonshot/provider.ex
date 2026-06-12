defmodule BeamWeaver.Moonshot.Provider do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def provider, do: :moonshot

  @impl true
  def profiles, do: ProfileRegistry.profiles(:moonshot)

  @impl true
  def chat_model(_opts), do: {:ok, BeamWeaver.Moonshot.ChatModel}

  @impl true
  def profile(model), do: ProfileRegistry.fetch(:moonshot, model)

  @impl true
  def infer_provider?(_model, _kind), do: false

  @impl true
  def default_model(:chat), do: "kimi-k2.6"
  def default_model(_kind), do: nil

  @impl true
  def capabilities,
    do: %{api_families: [:chat_completions], openai_compatible: true}
end
