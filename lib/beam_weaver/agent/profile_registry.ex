defmodule BeamWeaver.Agent.ProfileRegistry do
  @moduledoc false

  @spec register(term(), String.t() | atom(), struct(), map(), (struct(), struct() -> struct())) ::
          :ok
  def register(registry_key, key, incoming, exact_profiles, merge) when is_function(merge, 2) do
    canonical = validate_profile_key!(key)
    existing = Map.get(exact_profiles, canonical)
    profile = if existing, do: merge.(existing, incoming), else: incoming

    registry =
      registry_key
      |> persistent_get(%{})
      |> Map.put(canonical, %{profile | name: canonical})

    :persistent_term.put(registry_key, registry)
    :ok
  end

  @spec lookup(String.t() | atom() | nil, map(), (struct(), struct() -> struct())) ::
          struct() | nil
  def lookup(nil, _profiles, _merge), do: nil

  def lookup(spec, profiles, merge)
      when (is_atom(spec) or is_binary(spec)) and is_function(merge, 2) do
    with {:ok, canonical} <- profile_key(spec),
         false <- malformed_profile_key?(canonical) do
      {provider, model?} = split_profile_key(canonical)
      exact = Map.get(profiles, canonical)
      base = if model?, do: Map.get(profiles, provider)

      cond do
        exact && base -> merge.(base, exact)
        exact -> exact
        base -> base
        true -> nil
      end
    else
      _other -> nil
    end
  end

  @spec exact_profiles(map(), term()) :: map()
  def exact_profiles(builtin_profiles, registry_key),
    do: Map.merge(builtin_profiles, persistent_get(registry_key, %{}))

  @spec validate_profile_key!(String.t() | atom()) :: String.t()
  def validate_profile_key!(key) do
    case profile_key(key) do
      {:ok, canonical} ->
        if malformed_profile_key?(canonical) do
          raise ArgumentError, "profile key must be a non-empty provider or provider:model string"
        else
          canonical
        end

      _other ->
        raise ArgumentError, "profile key must be a non-empty provider or provider:model string"
    end
  end

  @spec profile_key(String.t() | atom()) :: {:ok, String.t()} | :error
  def profile_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  def profile_key(key) when is_binary(key), do: {:ok, key}
  def profile_key(_key), do: :error

  @spec malformed_profile_key?(String.t()) :: boolean()
  def malformed_profile_key?(key) do
    key == "" or key != String.trim(key) or String.split(key, ":") |> malformed_profile_parts?()
  end

  @spec split_profile_key(String.t()) :: {String.t(), boolean()}
  def split_profile_key(key) do
    case String.split(key, ":", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {provider, true}
      [provider] -> {provider, false}
    end
  end

  @spec persistent_get(term(), term()) :: term()
  def persistent_get(key, default) do
    :persistent_term.get(key)
  rescue
    ArgumentError -> default
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec maybe_put_map(map(), atom(), term()) :: map()
  def maybe_put_map(map, _key, value) when value in [nil, %{}], do: map
  def maybe_put_map(map, key, value), do: Map.put(map, key, Map.new(value))

  @spec maybe_put_list(map(), atom(), term()) :: map()
  def maybe_put_list(map, _key, value) when value in [nil, []], do: map

  def maybe_put_list(map, key, value),
    do: Map.put(map, key, value |> List.wrap() |> Enum.map(&to_string/1) |> Enum.sort())

  defp malformed_profile_parts?([provider]), do: provider == ""
  defp malformed_profile_parts?([provider, model]), do: provider == "" or model == ""
  defp malformed_profile_parts?(_parts), do: true
end
