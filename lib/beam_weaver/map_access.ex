defmodule BeamWeaver.MapAccess do
  @moduledoc false

  def fetch(map, key)

  def fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, _value} = found -> found
      :error -> fetch_alternate(map, key)
    end
  end

  def fetch(_map, _key), do: :error

  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  def get(_map, _key, default), do: default

  def has_key?(map, key) when is_map(map), do: match?({:ok, _value}, fetch(map, key))

  def has_key?(_map, _key), do: false

  def first(map, keys, default \\ nil)

  def first(map, keys, default) when is_map(map) and is_list(keys) do
    case Enum.find_value(keys, fn key ->
           case fetch(map, key) do
             {:ok, value} -> {:ok, value}
             :error -> nil
           end
         end) do
      {:ok, value} -> value
      nil -> default
    end
  end

  def first(_map, _keys, default), do: default

  def normalize_keys(map, allowed_keys) when is_map(map) and is_list(allowed_keys) do
    allowed_by_string =
      Map.new(allowed_keys, fn key when is_atom(key) -> {Atom.to_string(key), key} end)

    Map.new(map, fn
      {key, value} when is_binary(key) -> {Map.get(allowed_by_string, key, key), value}
      pair -> pair
    end)
  end

  def normalize_keys(map, _allowed_keys), do: map

  defp fetch_alternate(map, key) when is_atom(key), do: Map.fetch(map, Atom.to_string(key))

  defp fetch_alternate(map, key) when is_binary(key) do
    Map.fetch(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> :error
  end

  defp fetch_alternate(_map, _key), do: :error
end
