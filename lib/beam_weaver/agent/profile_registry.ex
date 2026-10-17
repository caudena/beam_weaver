defmodule BeamWeaver.Agent.ProfileRegistry do
  @moduledoc false

  alias BeamWeaver.Agent.ModelResolver

  @spec register(term(), map(), String.t() | atom(), struct(), (struct(), struct() -> struct())) :: :ok
  def register(registry_key, builtin_profiles, key, incoming, merge) when is_function(merge, 2) do
    canonical =
      case profile_key(key) do
        {:ok, canonical, _parts} -> canonical
        :error -> raise ArgumentError, "profile key must be a non-empty provider or provider:model string"
      end

    existing = Map.get(exact_profiles(registry_key, builtin_profiles), canonical)
    profile = if existing, do: merge.(existing, incoming), else: incoming
    registry = registry_key |> :persistent_term.get(%{}) |> Map.put(canonical, %{profile | name: canonical})
    :persistent_term.put(registry_key, registry)
  end

  @spec lookup(term(), map(), String.t() | atom() | nil, (struct(), struct() -> struct())) :: struct() | nil
  def lookup(registry_key, builtin_profiles, spec, merge) when is_function(merge, 2) do
    profiles = exact_profiles(registry_key, builtin_profiles)

    case profile_key(spec) do
      {:ok, canonical, [_provider]} ->
        Map.get(profiles, canonical)

      {:ok, canonical, [provider, _model]} ->
        exact = Map.get(profiles, canonical)
        base = Map.get(profiles, provider)
        if exact && base, do: merge.(base, exact), else: exact || base

      :error ->
        nil
    end
  end

  def for_model(_model, spec, get) when is_binary(spec), do: get.(spec)
  def for_model(spec, nil, get) when is_binary(spec), do: get.(spec)

  def for_model(model, nil, get) do
    identifier = ModelResolver.get_model_identifier(model)
    provider = ModelResolver.get_model_provider(model)

    cond do
      provider && identifier && not String.contains?(identifier, ":") ->
        get.("#{provider}:#{identifier}") || get.(provider)

      identifier && String.contains?(identifier, ":") ->
        get.(identifier)

      provider ->
        get.(provider)

      true ->
        nil
    end
  end

  @spec maybe_put_map(map(), atom(), term()) :: map()
  def maybe_put_map(map, _key, value) when value in [nil, %{}], do: map
  def maybe_put_map(map, key, value), do: Map.put(map, key, Map.new(value))

  @spec maybe_put_list(map(), atom(), term()) :: map()
  def maybe_put_list(map, _key, value) when value in [nil, []], do: map

  def maybe_put_list(map, key, value),
    do: Map.put(map, key, value |> List.wrap() |> Enum.map(&to_string/1) |> Enum.sort())

  defp exact_profiles(registry_key, builtin_profiles),
    do: Map.merge(builtin_profiles, :persistent_term.get(registry_key, %{}))

  defp profile_key(key) when is_atom(key) or is_binary(key) do
    key = to_string(key)
    parts = String.split(key, ":")

    if key == String.trim(key) and length(parts) <= 2 and "" not in parts,
      do: {:ok, key, parts},
      else: :error
  end

  defp profile_key(_key), do: :error
end
