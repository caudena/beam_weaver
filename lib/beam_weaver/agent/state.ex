defmodule BeamWeaver.Agent.State do
  @moduledoc false

  @core_keys [
    :messages,
    :remaining_steps,
    :jump_to,
    :tool_set,
    :usage,
    :structured_response,
    :raw_input
  ]

  @string_key_aliases Map.new(@core_keys, fn key -> {Atom.to_string(key), key} end)

  @spec project(map(), map() | nil) :: map()
  def project(input, schema \\ nil) when is_map(input) do
    known_keys = schema_keys(schema)

    projected =
      known_keys
      |> Enum.reduce(%{}, fn key, acc ->
        case fetch_known(input, key) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)
      |> Map.merge(atom_extras(input, known_keys))

    raw_input = raw_input(input, known_keys)
    existing_raw = Map.get(projected, :raw_input)
    raw_input = merge_raw_input(raw_input, existing_raw)

    if map_size(raw_input) == 0 do
      projected
    else
      Map.put(projected, :raw_input, raw_input)
    end
  end

  @spec messages(map()) :: term()
  def messages(state) when is_map(state) do
    atom_messages = Map.get(state, :messages)
    string_messages = Map.get(state, "messages")

    cond do
      is_list(atom_messages) and is_list(string_messages) -> atom_messages ++ string_messages
      is_list(atom_messages) -> atom_messages
      is_list(string_messages) -> string_messages
      true -> atom_messages || string_messages || []
    end
  end

  @spec jump_to(map()) :: :model | :tools | :end | nil
  def jump_to(state) when is_map(state) do
    case Map.get(state, :jump_to, Map.get(state, "jump_to")) do
      value when value in [:model, "model"] -> :model
      value when value in [:tools, "tools"] -> :tools
      value when value in [:end, "end"] -> :end
      _other -> nil
    end
  end

  @spec structured_response?(map()) :: boolean()
  def structured_response?(state) when is_map(state),
    do: Map.has_key?(state, :structured_response) or Map.has_key?(state, "structured_response")

  @spec structured_response(map()) :: term()
  def structured_response(state) when is_map(state),
    do: Map.get(state, :structured_response, Map.get(state, "structured_response"))

  defp schema_keys(nil), do: MapSet.new(@core_keys)

  defp schema_keys(schema) when is_map(schema) do
    schema
    |> Map.keys()
    |> Enum.reduce(MapSet.new(@core_keys), fn
      key, acc when is_atom(key) ->
        MapSet.put(acc, key)

      key, acc when is_binary(key) ->
        case Map.fetch(@string_key_aliases, key) do
          {:ok, atom_key} -> MapSet.put(acc, atom_key)
          :error -> acc
        end

      _key, acc ->
        acc
    end)
  end

  defp schema_keys(_schema), do: MapSet.new(@core_keys)

  defp fetch_known(input, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(input, key) -> {:ok, Map.fetch!(input, key)}
      Map.has_key?(input, string_key) -> {:ok, Map.fetch!(input, string_key)}
      true -> :error
    end
  end

  defp atom_extras(input, known_keys) do
    input
    |> Enum.filter(fn {key, _value} -> is_atom(key) and not MapSet.member?(known_keys, key) end)
    |> Map.new()
  end

  defp raw_input(input, known_keys) do
    input
    |> Enum.filter(fn {key, _value} ->
      is_binary(key) and not known_string_key?(key, known_keys)
    end)
    |> Map.new()
  end

  defp known_string_key?(key, known_keys) do
    Enum.any?(known_keys, &(is_atom(&1) and Atom.to_string(&1) == key))
  end

  defp merge_raw_input(raw_input, nil), do: raw_input

  defp merge_raw_input(raw_input, existing_raw) when is_map(existing_raw) do
    raw_input
    |> Map.merge(existing_raw)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp merge_raw_input(raw_input, _existing_raw), do: raw_input
end
