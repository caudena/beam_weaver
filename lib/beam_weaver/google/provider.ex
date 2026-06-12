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
  def chat_model(_opts), do: {:ok, BeamWeaver.Google.ChatModel}

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
  def default_model(_kind), do: nil

  @impl true
  def capabilities, do: %{api_families: [:generate_content], provider_api: :gemini_developer}
end
