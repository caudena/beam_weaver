defmodule BeamWeaver.Serialization.JSON.Encoder do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result
  alias BeamWeaver.Serialization.Registry

  @type_tag "__beam_weaver_type__"
  @atom_keys_tag "__beam_weaver_atom_keys__"
  @reserved_keys [@type_tag, @atom_keys_tag]
  @plain_map_tag "map"

  # The key of a JSON object that names which of the map's keys were atoms:
  # `true` when all of them were, otherwise a sorted list of their names.
  @spec atom_keys_tag() :: String.t()
  def atom_keys_tag, do: @atom_keys_tag

  def encode(%DateTime{} = value, _registry),
    do: {:ok, %{@type_tag => "datetime", "value" => DateTime.to_iso8601(value)}}

  def encode(%NaiveDateTime{} = value, _registry),
    do: {:ok, %{@type_tag => "naive_datetime", "value" => NaiveDateTime.to_iso8601(value)}}

  def encode(%Date{} = value, _registry),
    do: {:ok, %{@type_tag => "date", "value" => Date.to_iso8601(value)}}

  def encode(%Time{} = value, _registry),
    do: {:ok, %{@type_tag => "time", "value" => Time.to_iso8601(value)}}

  # A struct's fields are known, so its keys need no atom marker.
  def encode(%{__struct__: module} = struct, registry) do
    case Registry.tag_for(registry, module) do
      nil ->
        {:error,
         Error.new(:unsupported_serialization_type, "struct type is not registered", %{
           module: inspect(module)
         })}

      tag ->
        with {:ok, fields} <- encode_object(Map.from_struct(struct), registry) do
          {:ok, Map.put(fields, @type_tag, tag)}
        end
    end
  end

  def encode(tuple, registry) when is_tuple(tuple) do
    with {:ok, items} <- encode(Tuple.to_list(tuple), registry) do
      {:ok, %{@type_tag => "tuple", "items" => items}}
    end
  end

  def encode(atom, _registry) when is_atom(atom),
    do: {:ok, %{@type_tag => "atom", "value" => Atom.to_string(atom)}}

  # A map whose keys are all strings or atoms is a JSON object; its atom keys
  # are named under `@atom_keys_tag`, so they load back as atoms. Any other
  # map, such as one with integer keys or with a reserved key, is a list of
  # entries whose keys are encoded like values.
  def encode(map, registry) when is_map(map) do
    with :ok <- check_key_collisions(map) do
      if Enum.all?(map, fn {key, _value} -> object_key?(key) end) do
        with {:ok, object} <- encode_object(map, registry), do: {:ok, put_atom_keys(object, map)}
      else
        encode_entries(map, registry)
      end
    end
  end

  def encode(list, registry) when is_list(list), do: Result.traverse(list, &encode(&1, registry))

  def encode(value, _registry) when is_binary(value) do
    if String.valid?(value) do
      {:ok, value}
    else
      {:ok, %{@type_tag => "binary", "base64" => Base.encode64(value)}}
    end
  end

  def encode(value, _registry)
      when is_number(value) or is_boolean(value) or is_nil(value),
      do: {:ok, value}

  def encode(value, _registry),
    do:
      {:error,
       Error.new(:unsupported_serialization_type, "value cannot be serialized safely", %{
         value: inspect(value)
       })}

  # `:status` and `"status"` would both be saved as "status".
  defp check_key_collisions(map) do
    case Enum.find(Map.keys(map), &(is_atom(&1) and Map.has_key?(map, Atom.to_string(&1)))) do
      nil ->
        :ok

      key ->
        {:error,
         Error.new(:unsupported_serialization_type, "map has colliding string/atom keys", %{
           key: Atom.to_string(key)
         })}
    end
  end

  defp object_key?(key) when key in @reserved_keys, do: false
  defp object_key?(key) when is_binary(key), do: String.valid?(key)
  defp object_key?(key) when is_atom(key), do: Atom.to_string(key) not in @reserved_keys
  defp object_key?(_key), do: false

  defp encode_object(map, registry) do
    with {:ok, fields} <- Result.traverse(map, &encode_field(&1, registry)), do: {:ok, Map.new(fields)}
  end

  defp encode_field({key, value}, registry) do
    with {:ok, encoded} <- encode(value, registry), do: {:ok, {key_name(key), encoded}}
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key

  defp put_atom_keys(object, map) do
    case map |> Map.keys() |> Enum.filter(&is_atom/1) do
      [] -> object
      atoms when length(atoms) == map_size(map) -> Map.put(object, @atom_keys_tag, true)
      atoms -> Map.put(object, @atom_keys_tag, atoms |> Enum.map(&Atom.to_string/1) |> Enum.sort())
    end
  end

  defp encode_entries(map, registry) do
    with {:ok, entries} <- Result.traverse(map, &encode_entry(&1, registry)),
         do: {:ok, %{@type_tag => @plain_map_tag, "entries" => entries}}
  end

  defp encode_entry({key, value}, registry) do
    with {:ok, encoded_key} <- encode(key, registry),
         {:ok, encoded_value} <- encode(value, registry),
         do: {:ok, %{"key" => encoded_key, "value" => encoded_value}}
  end
end
