defmodule BeamWeaver.MapShape do
  @moduledoc false

  @type compact_rule :: nil | :empty_string | :empty_list | :empty_map

  @spec compact(map(), [compact_rule()]) :: map()
  def compact(map, rules \\ [nil]) when is_map(map) do
    Map.reject(map, fn
      {_key, nil} -> nil in rules
      {_key, ""} -> :empty_string in rules
      {_key, []} -> :empty_list in rules
      {_key, value} when is_map(value) and map_size(value) == 0 -> :empty_map in rules
      _entry -> false
    end)
  end

  @spec put_optional(map(), term(), term()) :: map()
  def put_optional(map, _key, nil), do: map
  def put_optional(map, _key, []), do: map
  def put_optional(map, key, value), do: Map.put(map, key, value)

  @spec put_present(map() | keyword(), term(), term()) :: map() | keyword()
  def put_present(values, _key, nil), do: values
  def put_present(values, key, value) when is_list(values), do: Keyword.put(values, key, value)
  def put_present(values, key, value) when is_map(values), do: Map.put(values, key, value)

  @spec reject_nil_values(map()) :: map()
  def reject_nil_values(map), do: compact(map, [nil])

  @spec reject_nil_or_empty(map()) :: map()
  def reject_nil_or_empty(map), do: compact(map, [nil, :empty_string, :empty_list, :empty_map])

  @spec empty_to_nil(term()) :: term() | nil
  def empty_to_nil(map) when is_map(map) and map_size(map) == 0, do: nil
  def empty_to_nil(""), do: nil
  def empty_to_nil(value), do: value

  @spec stringify_keys(map()) :: map()
  def stringify_keys(%{__struct__: _module} = struct),
    do: struct |> Map.from_struct() |> stringify_keys()

  def stringify_keys(map) when is_map(map) do
    stringify_entries(map)
  end

  @spec stringify_entries(Enumerable.t()) :: map()
  def stringify_entries(entries) do
    Map.new(entries, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  @spec normalize_value(term()) :: term()
  def normalize_value(nil), do: nil
  def normalize_value(true), do: true
  def normalize_value(false), do: false
  def normalize_value(value) when is_map(value), do: stringify_keys(value)
  def normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  def normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  def normalize_value(value), do: value

  @spec assert_atom_keys_in!(list()) :: list()
  def assert_atom_keys_in!(values) when is_list(values) do
    Enum.each(values, fn
      value when is_map(value) and not is_struct(value) -> assert_atom_keys!(value)
      _value -> :ok
    end)

    values
  end

  @spec assert_atom_keys!(term()) :: term()
  def assert_atom_keys!(value), do: assert_keys!(value, &is_atom/1, "atom")

  @spec assert_string_keys!(term()) :: term()
  def assert_string_keys!(value), do: assert_keys!(value, &is_binary/1, "string")

  defp assert_keys!(map, valid_key?, kind) when is_map(map) do
    case Enum.find(map, fn {key, _value} -> not valid_key?.(key) end) do
      nil -> map
      {key, _value} -> raise ArgumentError, "expected #{kind} map keys, got #{inspect(key)}"
    end
  end

  defp assert_keys!(value, _valid_key?, kind),
    do: raise(ArgumentError, "expected map with #{kind} keys, got #{inspect(value)}")

  @spec assert_atom_keys_deep!(term()) :: term()
  def assert_atom_keys_deep!(map) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      unless is_atom(key), do: raise(ArgumentError, "expected atom map keys, got #{inspect(key)}")
      assert_atom_keys_deep!(value)
    end)

    map
  end

  def assert_atom_keys_deep!(list) when is_list(list) do
    Enum.each(list, &assert_atom_keys_deep!/1)
    list
  end

  def assert_atom_keys_deep!(value), do: value
end
