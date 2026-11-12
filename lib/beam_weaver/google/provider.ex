defmodule BeamWeaver.Google.Provider do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def provider, do: :google

  @impl true
  def profiles, do: ProfileRegistry.profiles(:google)

  @impl true
  def chat_model(opts) do
    if Keyword.get(opts, :model) == "gemini-decision-1" do
      {:error, Error.new(:unsupported_model, "Gemini Decision 1 uses Models.init_decision_model/2")}
    else
      {:ok, BeamWeaver.Google.ChatModel}
    end
  end

  @impl true
  def decision_model(opts) do
    case Keyword.get(opts, :model, "gemini-decision-1") do
      "gemini-decision-1" -> {:ok, BeamWeaver.Google.DecisionModel}
      model -> {:error, Error.new(:unsupported_model, "Gemini Decisions requires gemini-decision-1", %{model: model})}
    end
  end

  @impl true
  def embedding_model(_opts) do
    {:error,
     Error.new(
       :unsupported_provider,
       "Google embeddings are not part of the Gemini chat provider",
       %{
         provider: :google
       }
     )}
  end

  @impl true
  def profile(model), do: ProfileRegistry.fetch(:google, model)

  @impl true
  def infer_provider?(_model, _kind), do: false

  @impl true
  def default_model(:chat), do: "gemini-3.5-flash"
  def default_model(:decision), do: "gemini-decision-1"
  def default_model(_kind), do: nil

  @impl true
  def capabilities, do: %{api_families: [:generate_content, :decisions], provider_api: :gemini_developer}
end
