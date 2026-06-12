defmodule BeamWeaver.Serialization.JSON.Decoder do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Serialization.Registry

  @type_tag "__beam_weaver_type__"
  @plain_map_tag "map"

  def decode(%{@type_tag => @plain_map_tag, "entries" => entries}, registry)
      when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, %{}}, fn
      %{"key" => key, "value" => value}, {:ok, acc} when is_binary(key) ->
        case decode(value, registry) do
          {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      _entry, _acc ->
        {:halt, {:error, Error.new(:serialization_error, "encoded map entry is invalid")}}
    end)
  end

  def decode(%{@type_tag => @plain_map_tag}, _registry),
    do: {:error, Error.new(:serialization_error, "encoded map entries are invalid")}

  def decode(%{@type_tag => "tuple", "items" => items}, registry) do
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

  def decode(%{@type_tag => "atom", "value" => value}, _registry) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError ->
      {:error,
       Error.new(:unsupported_serialization_type, "atom is not loaded in the current VM", %{
         value: value
       })}
  end

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

  def decode(map, registry) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case decode(value, registry) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
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

  defp decode_struct_fields(map, module, registry) do
    allowed = module.__struct__() |> Map.from_struct() |> Map.keys() |> MapSet.new()

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
    BeamWeaver.Core.MessageLike.to_message(fields)
  end

  defp decode_struct(module, fields), do: {:ok, struct(module, fields)}
end
