defmodule BeamWeaver.Agent.ProviderProfile do
  @moduledoc """
  Default model options for a provider or `provider:model` spec, plus an
  optional `pre_init` hook that runs before the model is created.
  """

  import Kernel, except: [apply: 3]

  alias BeamWeaver.Agent.ProfileRegistry

  @registry_key {__MODULE__, :registry}

  @type t :: %__MODULE__{}

  defstruct name: nil,
            model_opts: [],
            init_kwargs: [],
            init_kwargs_factory: nil,
            pre_init: nil,
            provider: nil

  def new(opts \\ []), do: struct(__MODULE__, opts |> Map.new() |> normalize_keys())

  def builtin(:default), do: new(name: :default)
  def builtin(nil), do: nil
  def builtin(%__MODULE__{} = profile), do: profile

  def builtin(other) when is_atom(other) or is_binary(other),
    do: get_provider_profile(other) || new(name: other)

  @doc "Returns built-in provider profile keys supported by BeamWeaver."
  @spec builtin_keys() :: [String.t()]
  def builtin_keys, do: Map.keys(builtin_profiles()) |> Enum.sort()

  @doc "Registers or merges a provider profile under a provider or provider:model key."
  @spec register_provider_profile(String.t() | atom(), __MODULE__.t()) :: :ok
  def register_provider_profile(key, %__MODULE__{} = profile) do
    ProfileRegistry.register(@registry_key, builtin_profiles(), key, profile, &merge/2)
  end

  @doc "Looks up a provider profile for a provider or provider:model spec."
  @spec get_provider_profile(String.t() | atom() | nil) :: __MODULE__.t() | nil
  def get_provider_profile(nil), do: nil

  def get_provider_profile(spec) when is_atom(spec) or is_binary(spec) do
    ProfileRegistry.lookup(@registry_key, builtin_profiles(), spec, &merge/2)
  end

  @doc "Returns the provider profile that best matches a raw or resolved model."
  @spec for_model(term(), String.t() | nil) :: __MODULE__.t() | nil
  def for_model(model, spec \\ nil), do: ProfileRegistry.for_model(model, spec, &get_provider_profile/1)

  @doc "Applies a registered provider profile to model-construction options."
  @spec apply_provider_profile(String.t(), keyword() | map(), keyword()) :: keyword()
  def apply_provider_profile(spec, opts \\ [], runtime_opts \\ []) do
    caller = opts |> Map.new() |> Enum.to_list()

    case get_provider_profile(spec) do
      nil ->
        caller

      %__MODULE__{} = profile ->
        if Keyword.get(runtime_opts, :run_pre_init, true) and is_function(profile.pre_init, 1) do
          profile.pre_init.(spec)
        end

        profile
        |> profile_opts()
        |> Keyword.merge(caller)
    end
  end

  @doc "Merges two provider profiles, layering the override on top."
  @spec merge(__MODULE__.t(), __MODULE__.t()) :: __MODULE__.t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = override) do
    new(
      name: override.name || base.name,
      provider: override.provider || base.provider,
      model_opts: Keyword.merge(List.wrap(base.model_opts), List.wrap(override.model_opts)),
      init_kwargs: Keyword.merge(List.wrap(base.init_kwargs), List.wrap(override.init_kwargs)),
      init_kwargs_factory: merge_factories(base.init_kwargs_factory, override.init_kwargs_factory),
      pre_init: merge_pre_init(base.pre_init, override.pre_init)
    )
  end

  def apply(nil, model, opts), do: {model, opts}

  def apply(profile, model, opts) when is_atom(profile) or is_binary(profile),
    do: profile |> builtin() |> apply(model, opts)

  def apply(%__MODULE__{} = profile, model, opts) do
    if is_binary(model) and is_function(profile.pre_init, 1) do
      profile.pre_init.(model)
    end

    {model, Keyword.merge(profile_opts(profile), opts)}
  end

  @string_keys ~w(name provider model_opts init_kwargs init_kwargs_factory pre_init)

  defp normalize_keys(opts) do
    Map.new(opts, fn
      {key, value} when key in @string_keys -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end

  defp builtin_profiles do
    %{
      "openai" => new(name: :openai, init_kwargs: [use_responses_api: true])
    }
  end

  defp profile_opts(%__MODULE__{} = profile) do
    dynamic = if is_function(profile.init_kwargs_factory, 0), do: profile.init_kwargs_factory.(), else: []

    profile.model_opts
    |> List.wrap()
    |> Keyword.merge(List.wrap(profile.init_kwargs))
    |> Keyword.merge(dynamic |> Map.new() |> Enum.to_list())
  end

  defp merge_pre_init(nil, override), do: override
  defp merge_pre_init(base, nil), do: base

  defp merge_pre_init(base, override) do
    fn spec ->
      base.(spec)
      override.(spec)
    end
  end

  defp merge_factories(nil, override), do: override
  defp merge_factories(base, nil), do: base

  defp merge_factories(base, override) do
    fn -> Keyword.merge(base.() |> Map.new() |> Enum.to_list(), override.() |> Map.new() |> Enum.to_list()) end
  end
end
