defmodule BeamWeaver.Serialization.JSON.Encoder do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Serialization.Registry

  @type_tag "__beam_weaver_type__"
  @plain_map_tag "map"

  def encode(%DateTime{} = value, _registry),
    do: {:ok, %{@type_tag => "datetime", "value" => DateTime.to_iso8601(value)}}

  def encode(%NaiveDateTime{} = value, _registry),
    do: {:ok, %{@type_tag => "naive_datetime", "value" => NaiveDateTime.to_iso8601(value)}}

  def encode(%Date{} = value, _registry),
    do: {:ok, %{@type_tag => "date", "value" => Date.to_iso8601(value)}}

  def encode(%Time{} = value, _registry),
    do: {:ok, %{@type_tag => "time", "value" => Time.to_iso8601(value)}}

  def encode(%{__struct__: module} = struct, registry) do
    case Registry.tag_for(registry, module) do
      nil ->
        {:error,
         Error.new(:unsupported_serialization_type, "struct type is not registered", %{
           module: inspect(module)
         })}

      tag ->
        with {:ok, fields} <- encode(Map.from_struct(struct), registry) do
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

  def encode(map, registry) when is_map(map) do
    with {:ok, encoded_map} <- encode_map_entries(map, registry) do
      if Map.has_key?(encoded_map, @type_tag) do
        {:ok,
         %{
           @type_tag => @plain_map_tag,
           "entries" =>
             Enum.map(encoded_map, fn {key, value} ->
               %{"key" => key, "value" => value}
             end)
         }}
      else
        {:ok, encoded_map}
      end
    end
  end

  def encode(list, registry) when is_list(list) do
    case Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
           case encode(value, registry) do
             {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
             {:error, %Error{} = error} -> {:halt, {:error, error}}
           end
         end) do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

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

  defp encode_map_entries(map, registry) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      encoded_key = encode_key(key)

      if Map.has_key?(acc, encoded_key) do
        {:halt,
         {:error,
          Error.new(:unsupported_serialization_type, "map has colliding string/atom keys", %{
            key: encoded_key
          })}}
      else
        case encode(value, registry) do
          {:ok, encoded_value} -> {:cont, {:ok, Map.put(acc, encoded_key, encoded_value)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end
    end)
  end

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key), do: to_string(key)
end
