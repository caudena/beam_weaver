defmodule BeamWeaver.Provider.Registry do
  @moduledoc """
  Runtime registry for provider adapters and model profile lookup.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry

  @registry_key {__MODULE__, :registry}

  @type entry :: %{
          provider: atom(),
          adapter: module() | nil,
          chat_model: module() | nil,
          embedding_model: module() | nil,
          profiles: [Profile.t()],
          capabilities: map()
        }

  @doc "Loads provider registrations from application config."
  @spec load_from_config!() :: :ok
  def load_from_config! do
    BeamWeaver.Config.group(:providers, [])
    |> Enum.each(fn
      {provider, spec} -> register(provider, spec)
      adapter when is_atom(adapter) -> register(adapter.provider(), adapter)
    end)
  end

  @doc "Registers a provider adapter or provider spec."
  @spec register(atom(), module() | map() | keyword()) :: :ok
  def register(provider, spec) when is_atom(provider) do
    entry = build_entry(provider, spec)

    registry =
      @registry_key
      |> persistent_get(%{})
      |> Map.put(provider, entry)

    :persistent_term.put(@registry_key, registry)
    :ok
  end

  @doc "Unregisters a runtime provider registration."
  @spec unregister(atom() | String.t()) :: :ok
  def unregister(provider) do
    with {:ok, provider} <- normalize_provider(provider) do
      registry =
        @registry_key
        |> persistent_get(%{})
        |> Map.delete(provider)

      :persistent_term.put(@registry_key, registry)
    end

    :ok
  end

  @doc "Fetches a registered provider entry."
  @spec fetch(atom() | String.t()) :: {:ok, entry()} | {:error, Error.t()}
  def fetch(provider) do
    with {:ok, provider} <- normalize_provider(provider) do
      case Map.fetch(entries(), provider) do
        {:ok, entry} ->
          {:ok, entry}

        :error ->
          {:error, Error.new(:unsupported_provider, "unsupported provider", %{provider: provider})}
      end
    end
  end

  @doc "Returns all registered provider IDs."
  @spec providers() :: [atom()]
  def providers do
    entries()
    |> Map.keys()
    |> Enum.sort()
  end

  @doc "Returns all known profiles from registered providers."
  @spec profiles() :: [Profile.t()]
  def profiles do
    entries()
    |> Map.values()
    |> Enum.flat_map(& &1.profiles)
    |> Enum.sort_by(&{to_string(&1.provider), &1.id})
  end

  @doc "Fetches a model profile through the provider registry."
  @spec profile(atom() | String.t(), String.t()) :: {:ok, Profile.t()} | {:error, Error.t()}
  def profile(provider, model) do
    with {:ok, entry} <- fetch(provider) do
      if entry.adapter && function_exported?(entry.adapter, :profile, 1) do
        entry.adapter.profile(model)
      else
        case Enum.find(entry.profiles, &(&1.id == model)) do
          %Profile{} = profile -> {:ok, profile}
          nil -> ProfileRegistry.fetch(entry.provider, model)
        end
      end
    end
  end

  @doc "Returns the chat model module for a provider."
  @spec chat_provider(atom() | String.t(), keyword()) :: {:ok, module()} | {:error, Error.t()}
  def chat_provider(provider, opts \\ []) do
    with {:ok, entry} <- fetch(provider) do
      cond do
        entry.adapter && function_exported?(entry.adapter, :chat_model, 1) ->
          entry.adapter.chat_model(opts)

        entry.chat_model ->
          {:ok, entry.chat_model}

        true ->
          {:error,
           Error.new(:unsupported_provider, "unsupported chat model provider", %{
             provider: entry.provider
           })}
      end
    end
  end

  @doc "Returns the embedding model module for a provider."
  @spec embedding_provider(atom() | String.t(), keyword()) ::
          {:ok, module()} | {:error, Error.t()}
  def embedding_provider(provider, opts \\ []) do
    with {:ok, entry} <- fetch(provider) do
      cond do
        entry.adapter && function_exported?(entry.adapter, :embedding_model, 1) ->
          entry.adapter.embedding_model(opts)

        entry.embedding_model ->
          {:ok, entry.embedding_model}

        true ->
          {:error,
           Error.new(:unsupported_provider, "unsupported embedding model provider", %{
             provider: entry.provider
           })}
      end
    end
  end

  @doc """
  Infers the provider for a bare model ID.

  Gemini IDs are intentionally not inferred; callers must use `google:gemini-*`.
  """
  @spec infer_provider(String.t(), atom()) :: atom()
  def infer_provider(model, kind) do
    entries()
    |> Map.values()
    |> Enum.find_value(fn entry ->
      if entry.adapter && function_exported?(entry.adapter, :infer_provider?, 2) &&
           entry.adapter.infer_provider?(model, kind) do
        entry.provider
      end
    end)
    |> Kernel.||(:openai)
  end

  @doc false
  def provider_atom(provider) when is_atom(provider), do: provider

  def provider_atom(provider) when is_binary(provider) do
    case normalize_provider(provider) do
      {:ok, atom} when is_atom(atom) -> atom
      _other -> provider
    end
  end

  defp entries do
    Map.merge(builtin_entries(), persistent_get(@registry_key, %{}))
  end

  defp builtin_entries do
    [
      BeamWeaver.OpenAI.Provider,
      BeamWeaver.Anthropic.Provider,
      BeamWeaver.XAI.Provider,
      BeamWeaver.Google.Provider,
      BeamWeaver.Moonshot.Provider,
      BeamWeaver.ZAI.Provider,
      BeamWeaver.Provider.Fake
    ]
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> Map.new(fn adapter ->
      provider = adapter.provider()
      {provider, build_entry(provider, adapter)}
    end)
  end

  defp build_entry(provider, adapter) when is_atom(adapter) do
    %{
      provider: provider,
      adapter: adapter,
      chat_model: callback_value(adapter, :chat_model, [[]]),
      embedding_model: callback_value(adapter, :embedding_model, [[]]),
      profiles: callback_value(adapter, :profiles, []) || [],
      capabilities: callback_value(adapter, :capabilities, []) || %{}
    }
  end

  defp build_entry(provider, spec) when is_list(spec), do: build_entry(provider, Map.new(spec))

  defp build_entry(provider, spec) when is_map(spec) do
    adapter = BeamWeaver.MapAccess.get(spec, :adapter)

    base =
      if is_atom(adapter) do
        build_entry(provider, adapter)
      else
        %{
          provider: provider,
          adapter: nil,
          chat_model: nil,
          embedding_model: nil,
          profiles: [],
          capabilities: %{}
        }
      end

    %{
      base
      | chat_model: Map.get(spec, :chat_model, Map.get(spec, "chat_model", base.chat_model)),
        embedding_model: Map.get(spec, :embedding_model, Map.get(spec, "embedding_model", base.embedding_model)),
        profiles: normalize_profiles(Map.get(spec, :profiles, Map.get(spec, "profiles", base.profiles))),
        capabilities: Map.get(spec, :capabilities, Map.get(spec, "capabilities", base.capabilities))
    }
  end

  defp normalize_profiles(profiles) when is_list(profiles), do: Enum.map(profiles, &Profile.new/1)
  defp normalize_profiles(_profiles), do: []

  defp callback_value(adapter, callback, args) do
    arity = length(args)

    if function_exported?(adapter, callback, arity) do
      case apply(adapter, callback, args) do
        {:ok, value} -> value
        {:error, _error} -> nil
        value -> value
      end
    end
  end

  defp normalize_provider(provider) when is_atom(provider), do: {:ok, provider}

  defp normalize_provider(provider) when is_binary(provider) do
    original = provider

    provider =
      entries()
      |> Map.keys()
      |> Enum.find(&(Atom.to_string(&1) == provider))

    if provider do
      {:ok, provider}
    else
      {:error, Error.new(:unsupported_provider, "unsupported provider", %{provider: original})}
    end
  end

  defp persistent_get(key, default) do
    :persistent_term.get(key)
  rescue
    ArgumentError -> default
  end
end
