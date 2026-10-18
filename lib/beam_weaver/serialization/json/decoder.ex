defmodule BeamWeaver.Serialization.JSON.Decoder do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result
  alias BeamWeaver.Serialization.Registry

  require Logger

  @type_tag "__beam_weaver_type__"
  @atom_keys_tag "__beam_weaver_atom_keys__"
  @plain_map_tag "map"
  @calendar_types %{"datetime" => DateTime, "naive_datetime" => NaiveDateTime, "date" => Date, "time" => Time}

  def decode(%{@type_tag => @plain_map_tag, "entries" => entries}, registry)
      when is_list(entries) do
    with {:ok, pairs} <- Result.traverse(entries, &decode_entry(&1, registry)), do: {:ok, Map.new(pairs)}
  end

  def decode(%{@type_tag => @plain_map_tag}, _registry),
    do: {:error, Error.new(:serialization_error, "encoded map entries are invalid")}

  def decode(%{@type_tag => "tuple", "items" => items}, registry) when is_list(items) do
    with {:ok, items} <- decode(items, registry), do: {:ok, List.to_tuple(items)}
  end

  def decode(%{@type_tag => "binary", "base64" => value}, _registry) when is_binary(value) do
    with :error <- Base.decode64(value),
         do: {:error, Error.new(:serialization_error, "encoded binary payload is not valid base64")}
  end

  def decode(%{@type_tag => tag, "value" => value}, _registry)
      when is_map_key(@calendar_types, tag) and is_binary(value) do
    module = @calendar_types[tag]

    case module.from_iso8601(value) do
      {:ok, decoded, _offset} ->
        {:ok, decoded}

      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error, Error.new(:serialization_error, "encoded #{inspect(module)} is invalid", %{reason: inspect(reason)})}
    end
  end

  def decode(%{@type_tag => "atom", "value" => value}, _registry) when is_binary(value), do: existing_atom(value)

  def decode(%{@type_tag => tag}, _registry)
      when tag in ["atom", "tuple", "binary", "datetime", "naive_datetime", "date", "time"],
      do: {:error, Error.new(:serialization_error, "encoded #{tag} is invalid")}

  def decode(%{@type_tag => tag} = map, registry) do
    fields = Map.delete(map, @type_tag)

    case Registry.module_for(registry, tag) do
      nil ->
        field_map(fields, registry, tag, "no module is registered for the tag")

      module ->
        if Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0) do
          with {:ok, fields} <- decode_struct_fields(fields, module, registry), do: decode_struct(module, fields)
        else
          field_map(fields, registry, tag, "#{inspect(module)}, registered for the tag, isn't available")
        end
    end
  end

  # A JSON object. The keys that `@atom_keys_tag` names come back as atoms.
  # Objects saved without it, before map keys kept their types, keep string
  # keys.
  def decode(map, registry) when is_map(map) do
    {atom_keys, map} = pop_atom_keys(map)

    decoded =
      Result.traverse(map, fn {key, value} ->
        with {:ok, key} <- restore_key(key, atom_keys),
             {:ok, decoded} <- decode(value, registry),
             do: {:ok, {key, decoded}}
      end)

    with {:ok, pairs} <- decoded, do: {:ok, Map.new(pairs)}
  end

  def decode(list, registry) when is_list(list), do: Result.traverse(list, &decode(&1, registry))

  def decode(value, _registry), do: {:ok, value}

  # A struct that can't be rebuilt loads as a map of its fields, with string
  # keys, so the rest of the value still loads.
  defp field_map(fields, registry, tag, reason) do
    warn_once({:struct, tag}, "Loaded a saved #{inspect(tag)} struct as a map of its fields: #{reason}.")
    decode(fields, registry)
  end

  # Once per tag or atom in the VM, however many values hold it.
  defp warn_once(key, message) do
    key = {__MODULE__, :warned, key}

    if not :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      Logger.warning(message)
    end
  end

  defp decode_entry(%{"key" => key, "value" => value}, registry) do
    with {:ok, key} <- decode_key(key, registry),
         {:ok, decoded} <- decode(value, registry),
         do: {:ok, {key, decoded}}
  end

  defp decode_entry(_entry, _registry),
    do: {:error, Error.new(:serialization_error, "encoded map entry is invalid")}

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

  defp atom_key(name), do: existing_atom(name)

  # Loading never creates atoms: an atom, or an atom key, that no loaded code
  # uses comes back as its name.
  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError ->
      warn_once({:atom, name}, "Loaded the saved atom #{inspect(name)} as a string: no loaded code uses it.")
      {:ok, name}
  end

  # An exception's `__exception__` field comes from its module, like
  # `__struct__`.
  defp decode_struct_fields(map, module, registry) do
    allowed = module.__struct__() |> Map.from_struct() |> Map.delete(:__exception__) |> Map.keys()

    fields = for {key, value} <- map, field = Enum.find(allowed, &(Atom.to_string(&1) == key)), do: {field, value}

    decoded =
      Result.traverse(fields, fn {field, value} ->
        with {:ok, decoded} <- decode(value, registry), do: {:ok, {field, decoded}}
      end)

    with {:ok, pairs} <- decoded, do: {:ok, Map.new(pairs)}
  end

  defp decode_struct(BeamWeaver.Core.Message, fields) do
    BeamWeaver.Core.Message.from(fields)
  end

  defp decode_struct(BeamWeaver.TypeSafe.Response, fields),
    do: {:ok, BeamWeaver.TypeSafe.Response.from_serialized(fields)}

  defp decode_struct(module, fields), do: {:ok, struct(module, fields)}
end
