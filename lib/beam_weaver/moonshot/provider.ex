defmodule BeamWeaver.Moonshot.Provider do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def provider, do: :moonshot

  @impl true
  def profiles, do: ProfileRegistry.profiles(:moonshot)

  @impl true
  def chat_model(opts) do
    case Keyword.get(opts, :api) do
      api when api in [nil, :chat_completions, "chat_completions"] ->
        {:ok, BeamWeaver.Moonshot.ChatModel}

      api when api in [:responses, "responses"] ->
        model = Keyword.get(opts, :model, default_model(:chat))

        if ProfileRegistry.Moonshot.k3_model?(model),
          do: {:ok, BeamWeaver.Moonshot.ResponsesModel},
          else: {:error, Error.new(:unsupported_model, "Kimi Responses requires a K3 series model", %{model: model})}

      api ->
        {:error, Error.new(:invalid_provider_option, "unsupported Moonshot API selection", %{api: api})}
    end
  end

  @impl true
  def profile(model), do: ProfileRegistry.fetch(:moonshot, model)

  @impl true
  def infer_provider?(_model, _kind), do: false

  @impl true
  def default_model(:chat), do: ProfileRegistry.Moonshot.default_model()
  def default_model(_kind), do: nil

  @impl true
  def capabilities,
    do: %{api_families: [:chat_completions, :responses], openai_compatible: true}
end
