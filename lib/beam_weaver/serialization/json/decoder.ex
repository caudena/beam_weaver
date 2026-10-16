defmodule BeamWeaver.Serialization.JSON.Decoder do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Serialization.Registry

  @type_tag "__beam_weaver_type__"
  @atom_keys_tag "__beam_weaver_atom_keys__"
  @plain_map_tag "map"

  def decode(%{@type_tag => @plain_map_tag, "entries" => entries}, registry)
      when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, %{}}, fn
      %{"key" => key, "value" => value}, {:ok, acc} ->
        with {:ok, key} <- decode_key(key, registry),
             {:ok, decoded} <- decode(value, registry) do
          {:cont, {:ok, Map.put(acc, key, decoded)}}
        else
          {:error, %Error{}} = error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, Error.new(:serialization_error, "encoded map entry is invalid")}}
    end)
  end

  def decode(%{@type_tag => @plain_map_tag}, _registry),
    do: {:error, Error.new(:serialization_error, "encoded map entries are invalid")}

  def decode(%{@type_tag => "tuple", "items" => items}, registry) when is_list(items) do
    with {:ok, items} <- decode(items, registry), do: {:ok, List.to_tuple(items)}
  end

  def decode(%{@type_tag => "binary", "base64" => value}, _registry) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, binary} ->
        {:ok, binary}

      :error ->
        {:error, Error.new(:serialization_error, "encoded binary payload is not valid base64")}
    end
  end

  def decode(%{@type_tag => "datetime", "value" => value}, _registry)
      when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, reason} ->
        {:error,
         Error.new(:serialization_error, "encoded DateTime is invalid", %{
           reason: inspect(reason)
         })}
    end
  end

  def decode(%{@type_tag => "naive_datetime", "value" => value}, _registry)
      when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} ->
        {:ok, datetime}

      {:error, reason} ->
        {:error,
         Error.new(:serialization_error, "encoded NaiveDateTime is invalid", %{
           reason: inspect(reason)
         })}
    end
  end

  def decode(%{@type_tag => "date", "value" => value}, _registry) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, date}

      {:error, reason} ->
        {:error, Error.new(:serialization_error, "encoded Date is invalid", %{reason: inspect(reason)})}
    end
  end

  def decode(%{@type_tag => "time", "value" => value}, _registry) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} ->
        {:ok, time}

      {:error, reason} ->
        {:error, Error.new(:serialization_error, "encoded Time is invalid", %{reason: inspect(reason)})}
    end
  end

  def decode(%{@type_tag => "atom", "value" => value}, _registry) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError ->
      {:error,
       Error.new(:unsupported_serialization_type, "atom is not loaded in the current VM", %{
         value: value
       })}
  end

  def decode(%{@type_tag => tag}, _registry) when tag in ["atom", "tuple"],
    do: {:error, Error.new(:serialization_error, "encoded #{tag} is invalid")}

  def decode(%{@type_tag => tag} = map, registry) do
    case Registry.module_for(registry, tag) do
      nil ->
        {:error,
         Error.new(:unsupported_serialization_type, "encoded struct type is not registered", %{
           tag: tag
         })}

      module ->
        fields =
          map
          |> Map.delete(@type_tag)
          |> decode_struct_fields(module, registry)

        case fields do
          {:ok, fields} -> decode_struct(module, fields)
          error -> error
        end
    end
  end

  # A JSON object. The keys that `@atom_keys_tag` names come back as atoms.
  # Objects saved without it, before map keys kept their types, keep string
  # keys.
  def decode(map, registry) when is_map(map) do
    {atom_keys, map} = pop_atom_keys(map)

    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- restore_key(key, atom_keys),
           {:ok, decoded} <- decode(value, registry) do
        {:cont, {:ok, Map.put(acc, key, decoded)}}
      else
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  def decode(list, registry) when is_list(list) do
    case Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
           case decode(value, registry) do
             {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
             {:error, %Error{} = error} -> {:halt, {:error, error}}
           end
         end) do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def decode(value, _registry), do: {:ok, value}

  defp pop_atom_keys(%{@atom_keys_tag => true} = map), do: {:all, Map.delete(map, @atom_keys_tag)}

  defp pop_atom_keys(%{@atom_keys_tag => names} = map) when is_list(names) do
    if Enum.all?(names, &is_binary/1),
      do: {MapSet.new(names), Map.delete(map, @atom_keys_tag)},
      else: {:none, map}
  end

  defp pop_atom_keys(map), do: {:none, map}

  defp restore_key(key, :none), do: {:ok, key}
  defp restore_key(key, :all), do: atom_key(key)
  defp restore_key(key, names), do: if(MapSet.member?(names, key), do: atom_key(key), else: {:ok, key})

  # A key in a map's entries: atoms are tagged, other keys are encoded like
  # values.
  defp decode_key(%{@type_tag => "atom", "value" => name}, _registry) when is_binary(name),
    do: atom_key(name)

  defp decode_key(key, registry), do: decode(key, registry)

  # A map with an atom `__struct__` key is a struct, of whatever module the
  # key names. Structs are saved tagged, and only the registry's come back, so
  # a map naming it wasn't saved by this codec.
  defp atom_key("__struct__") do
    {:error, Error.new(:serialization_error, "encoded map has a __struct__ key")}
  end

  # Loading never creates atoms: an atom key that doesn't exist in this VM,
  # because no loaded code uses it, stays a string.
  defp atom_key(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:ok, name}
  end

  # An exception's `__exception__` field comes from its module, like
  # `__struct__`.
  defp decode_struct_fields(map, module, registry) do
    allowed =
      module.__struct__()
      |> Map.from_struct()
      |> Map.delete(:__exception__)
      |> Map.keys()
      |> MapSet.new()

    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      atom_key = existing_field(key, allowed)

      if atom_key do
        case decode(value, registry) do
          {:ok, decoded} -> {:cont, {:ok, Map.put(acc, atom_key, decoded)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp existing_field(key, allowed) when is_binary(key) do
    Enum.find(allowed, &(Atom.to_string(&1) == key))
  end

  defp existing_field(key, allowed) when is_atom(key) do
    if MapSet.member?(allowed, key), do: key
  end

  defp decode_struct(BeamWeaver.Core.Message, fields) do
    BeamWeaver.Core.Message.from(fields)
  end

  defp decode_struct(BeamWeaver.TypeSafe.Response, fields),
    do: {:ok, BeamWeaver.TypeSafe.Response.from_serialized(fields)}

  defp decode_struct(module, fields), do: {:ok, struct(module, fields)}
end
