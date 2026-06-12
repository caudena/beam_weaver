defmodule BeamWeaver.Models.ProfileRegistry do
  @moduledoc """
  Registry facade for model profiles and provider modules.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Anthropic
  alias BeamWeaver.Models.ProfileRegistry.Fake
  alias BeamWeaver.Models.ProfileRegistry.Fallbacks
  alias BeamWeaver.Models.ProfileRegistry.Google
  alias BeamWeaver.Models.ProfileRegistry.Moonshot
  alias BeamWeaver.Models.ProfileRegistry.OpenAI
  alias BeamWeaver.Models.ProfileRegistry.XAI

  @provider_modules %{
    anthropic: Anthropic,
    fake: Fake,
    google: Google,
    moonshot: Moonshot,
    openai: OpenAI,
    xai: XAI
  }

  @profile_modules [OpenAI, Anthropic, XAI, Moonshot, Google, Fake]

  @doc """
  Returns all checked-in model profiles sorted by provider and id.
  """
  @spec all() :: [Profile.t()]
  def all do
    @profile_modules
    |> Enum.flat_map(& &1.profiles())
    |> Enum.sort_by(&{to_string(&1.provider), &1.id})
  end

  @doc """
  Returns all providers with checked-in profile data.
  """
  @spec providers() :: [atom()]
  def providers do
    BeamWeaver.Provider.Registry.providers()
  end

  @doc """
  Returns checked-in profiles for one provider.
  """
  @spec profiles(atom()) :: [Profile.t()]
  def profiles(provider) when is_atom(provider) do
    provider
    |> provider_module()
    |> case do
      nil -> []
      module -> Enum.sort_by(module.profiles(), & &1.id)
    end
  end

  @doc """
  Fetches a model profile.
  """
  @spec fetch(atom(), String.t()) :: {:ok, Profile.t()} | {:error, Error.t()}
  def fetch(provider, model) do
    provider
    |> resolve_profile(model)
    |> finalize_resolved_profile()
  end

  @doc """
  Returns a provider module for chat models.
  """
  def chat_provider(provider), do: BeamWeaver.Provider.Registry.chat_provider(provider)

  @doc """
  Returns a provider module for embedding models.
  """
  def embedding_provider(provider), do: BeamWeaver.Provider.Registry.embedding_provider(provider)

  defp resolve_profile(provider, model) do
    case provider_module(provider) do
      nil -> {:fallback, provider, model}
      module -> module.resolve(model)
    end
  end

  defp provider_module(provider), do: Map.get(@provider_modules, provider)

  defp finalize_resolved_profile({:ok, %Profile{} = profile}), do: {:ok, profile}

  defp finalize_resolved_profile({:fallback, provider, model}),
    do: {:ok, Fallbacks.profile(provider, model)}

  defp finalize_resolved_profile({:error, %Error{} = error}), do: {:error, error}
end
