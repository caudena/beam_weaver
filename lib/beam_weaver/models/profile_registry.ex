defmodule BeamWeaver.Models.ProfileRegistry do
  @moduledoc """
  Registry facade for model profiles and provider modules.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Anthropic
  alias BeamWeaver.Models.ProfileRegistry.DeepSeek
  alias BeamWeaver.Models.ProfileRegistry.Fake
  alias BeamWeaver.Models.ProfileRegistry.Fallbacks
  alias BeamWeaver.Models.ProfileRegistry.Google
  alias BeamWeaver.Models.ProfileRegistry.Moonshot
  alias BeamWeaver.Models.ProfileRegistry.OpenAI
  alias BeamWeaver.Models.ProfileRegistry.XAI
  alias BeamWeaver.Models.ProfileRegistry.TypeSafe
  alias BeamWeaver.Models.ProfileRegistry.ZAI

  @provider_modules %{
    anthropic: Anthropic,
    deepseek: DeepSeek,
    fake: Fake,
    google: Google,
    moonshot: Moonshot,
    openai: OpenAI,
    xai: XAI,
    typesafe: TypeSafe,
    zai: ZAI
  }

  @doc """
  Returns all checked-in model profiles sorted by provider and id.
  """
  @spec all() :: [Profile.t()]
  def all do
    @provider_modules
    |> Map.values()
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
    case Map.get(@provider_modules, provider) do
      nil -> []
      module -> Enum.sort_by(module.profiles(), & &1.id)
    end
  end

  @doc """
  Fetches a model profile.
  """
  @spec fetch(atom(), String.t()) :: {:ok, Profile.t()} | {:error, Error.t()}
  def fetch(provider, model) do
    resolved =
      case Map.get(@provider_modules, provider) do
        nil -> {:fallback, provider, model}
        module -> module.resolve(model)
      end

    with {:fallback, provider, model} <- resolved, do: {:ok, Fallbacks.profile(provider, model)}
  end

  @doc """
  Returns a provider module for chat models.
  """
  def chat_provider(provider), do: BeamWeaver.Provider.Registry.chat_provider(provider)

  @doc """
  Returns a provider module for embedding models.
  """
  def embedding_provider(provider), do: BeamWeaver.Provider.Registry.embedding_provider(provider)

  @doc false
  # Looks a model up in a provider's profile table; unknown models fall back
  # to the provider's family defaults.
  def fetch_or_fallback(profiles, provider, model) do
    case Map.fetch(profiles, {provider, model}) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:fallback, provider, model}
    end
  end

  @doc false
  def deprecated_error(provider, model, message, metadata) do
    details = Map.merge(metadata, %{provider: provider, model: model, expected: "#{provider}:#{metadata.replacement}"})
    {:error, Error.new(:deprecated_model, message, details)}
  end

  @doc false
  def fetch_alias(profiles, provider, alias_id, canonical_id) do
    case Map.fetch(profiles, {provider, canonical_id}) do
      {:ok, profile} ->
        extra = Map.merge(profile.extra, %{canonical_model: canonical_id, alias_model: alias_id})
        {:ok, %{profile | id: alias_id, name: "#{profile.name} (alias)", extra: extra}}

      :error ->
        {:fallback, provider, alias_id}
    end
  end
end
