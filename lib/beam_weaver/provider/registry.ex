defmodule BeamWeaver.Provider.Registry do
  @moduledoc """
  Runtime registry for provider adapters and model profile lookup.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry

  @registry_key {__MODULE__, :registry}
  @builtin_key {__MODULE__, :builtin}
  @builtin_adapters [
    BeamWeaver.OpenAI.Provider,
    BeamWeaver.Anthropic.Provider,
    BeamWeaver.XAI.Provider,
    BeamWeaver.Google.Provider,
    BeamWeaver.TypeSafe.Provider,
    BeamWeaver.Moonshot.Provider,
    BeamWeaver.ZAI.Provider,
    BeamWeaver.DeepSeek.Provider,
    BeamWeaver.Provider.Fake
  ]

  @type entry :: %{
          provider: atom(),
          adapter: module() | nil,
          chat_model: module() | nil,
          embedding_model: module() | nil,
          decision_model: module() | nil,
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

    registry = @registry_key |> :persistent_term.get(%{}) |> Map.put(provider, entry)

    :persistent_term.put(@registry_key, registry)
    :ok
  end

  @doc "Unregisters a runtime provider registration."
  @spec unregister(atom() | String.t()) :: :ok
  def unregister(provider) do
    with {:ok, provider} <- normalize_provider(provider) do
      registry = @registry_key |> :persistent_term.get(%{}) |> Map.delete(provider)

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

  @doc "Returns the decision model module for a provider."
  def decision_provider(provider, opts \\ []) do
    with {:ok, entry} <- fetch(provider) do
      cond do
        entry.adapter && function_exported?(entry.adapter, :decision_model, 1) ->
          entry.adapter.decision_model(opts)

        entry.decision_model ->
          {:ok, entry.decision_model}

        true ->
          {:error,
           Error.new(:unsupported_feature, "provider does not offer decision models", %{provider: entry.provider})}
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

  defp entries, do: Map.merge(builtin_entries(), :persistent_term.get(@registry_key, %{}))

  # Built-in adapters never change at runtime; build their entries (profile
  # lists included) once per VM.
  defp builtin_entries do
    with nil <- :persistent_term.get(@builtin_key, nil) do
      entries = Map.new(@builtin_adapters, &{&1.provider(), build_entry(&1.provider(), &1)})
      :persistent_term.put(@builtin_key, entries)
      entries
    end
  end

  defp build_entry(provider, adapter) when is_atom(adapter) do
    %{
      provider: provider,
      adapter: adapter,
      chat_model: callback_value(adapter, :chat_model, [[]]),
      embedding_model: callback_value(adapter, :embedding_model, [[]]),
      decision_model: callback_value(adapter, :decision_model, [[]]),
      profiles: callback_value(adapter, :profiles, []) || [],
      capabilities: callback_value(adapter, :capabilities, []) || %{}
    }
  end

  defp build_entry(provider, spec) when is_list(spec), do: build_entry(provider, Map.new(spec))

  defp build_entry(provider, spec) when is_map(spec) do
    base =
      case spec[:adapter] do
        adapter when is_atom(adapter) and not is_nil(adapter) ->
          build_entry(provider, adapter)

        _none ->
          %{
            provider: provider,
            adapter: nil,
            chat_model: nil,
            embedding_model: nil,
            decision_model: nil,
            profiles: [],
            capabilities: %{}
          }
      end

    %{
      base
      | chat_model: Map.get(spec, :chat_model, base.chat_model),
        embedding_model: Map.get(spec, :embedding_model, base.embedding_model),
        decision_model: Map.get(spec, :decision_model, base.decision_model),
        profiles: normalize_profiles(Map.get(spec, :profiles, base.profiles)),
        capabilities: Map.get(spec, :capabilities, base.capabilities)
    }
  end

  defp normalize_profiles(profiles) when is_list(profiles), do: Enum.map(profiles, &Profile.new/1)
  defp normalize_profiles(_profiles), do: []

  defp callback_value(adapter, callback, args) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, callback, length(args)) do
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
end
