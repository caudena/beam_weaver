defmodule BeamWeaver.Tool.Schema.Refs do
  @moduledoc false

  alias BeamWeaver.Core.Error

  def dereference_refs(schema, opts \\ []) do
    skip_keys =
      opts
      |> Keyword.get(:skip_keys, ["$defs", "definitions"])
      |> Enum.map(&to_string/1)

    dereference(schema, schema, skip_keys, [])
  end

  def remove_titles(schema), do: remove_titles(schema, false)

  defp dereference(%{} = value, root, skip_keys, seen_refs) do
    case fetch_ref(value) do
      {:ok, ref} ->
        dereference_ref(value, ref, root, skip_keys, seen_refs)

      :error ->
        dereference_map(value, root, skip_keys, seen_refs)
    end
  end

  defp dereference(values, root, skip_keys, seen_refs) when is_list(values) do
    case Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
           case dereference(value, root, skip_keys, seen_refs) do
             {:ok, dereferenced} -> {:cont, {:ok, [dereferenced | acc]}}
             {:error, %Error{} = error} -> {:halt, {:error, error}}
           end
         end) do
      {:ok, dereferenced} -> {:ok, Enum.reverse(dereferenced)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp dereference(value, _root, _skip_keys, _seen_refs), do: {:ok, value}

  defp remove_titles(schema, _properties_context?) when is_list(schema),
    do: Enum.map(schema, &remove_titles(&1, false))

  defp remove_titles(schema, properties_context?) when is_map(schema) do
    Enum.reduce(schema, %{}, fn {key, value}, acc ->
      cond do
        title_key?(key) and not properties_context? ->
          acc

        properties_key?(key) and is_map(value) ->
          Map.put(acc, key, remove_titles(value, true))

        true ->
          Map.put(acc, key, remove_titles(value, false))
      end
    end)
  end

  defp remove_titles(value, _properties_context?), do: value

  defp title_key?(key), do: key in [:title, "title"]
  defp properties_key?(key), do: key in [:properties, "properties"]

  defp dereference_ref(value, ref, root, skip_keys, seen_refs) do
    rest = delete_ref(value)

    with {:ok, rest} <- dereference_map(rest, root, skip_keys, seen_refs),
         {:ok, resolved} <- resolve_or_break_cycle(ref, root, skip_keys, seen_refs) do
      {:ok, merge_ref(resolved, rest)}
    end
  end

  defp resolve_or_break_cycle(ref, root, skip_keys, seen_refs) when is_binary(ref) do
    if ref in seen_refs do
      {:ok, %{}}
    else
      with {:ok, target} <- resolve_ref(root, ref) do
        dereference(target, root, skip_keys, [ref | seen_refs])
      end
    end
  end

  defp dereference_map(map, root, skip_keys, seen_refs) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if skip_key?(key, skip_keys) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        case dereference(value, root, skip_keys, seen_refs) do
          {:ok, dereferenced} -> {:cont, {:ok, Map.put(acc, key, dereferenced)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end
    end)
  end

  defp merge_ref(resolved, rest) when map_size(rest) == 0, do: resolved
  defp merge_ref(resolved, rest) when is_map(resolved), do: Map.merge(resolved, rest)
  defp merge_ref(_resolved, rest), do: rest

  defp fetch_ref(%{"$ref" => ref}) when is_binary(ref), do: {:ok, ref}
  defp fetch_ref(%{:"$ref" => ref}) when is_binary(ref), do: {:ok, ref}
  defp fetch_ref(_value), do: :error

  defp delete_ref(map) do
    map
    |> Map.delete("$ref")
    |> Map.delete(:"$ref")
  end

  defp skip_key?(key, skip_keys), do: to_string(key) in skip_keys

  defp resolve_ref(root, "#"), do: {:ok, root}

  defp resolve_ref(root, "#/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(&decode_pointer_segment/1)
    |> Enum.reduce_while({:ok, root}, fn segment, {:ok, value} ->
      case fetch_pointer(value, segment) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, missing_ref("#/" <> pointer)}
      end
    end)
  end

  defp resolve_ref(_root, ref) when is_binary(ref) do
    {:error,
     Error.new(:invalid_json_schema_ref, "JSON schema refs must be local URI fragments", %{
       ref: ref
     })}
  end

  defp fetch_pointer(%{} = map, segment) do
    cond do
      Map.has_key?(map, segment) ->
        {:ok, Map.fetch!(map, segment)}

      atom = existing_atom(segment) ->
        Map.fetch(map, atom)

      integer = integer_key(segment) ->
        Map.fetch(map, integer)

      true ->
        :error
    end
  end

  defp fetch_pointer(values, segment) when is_list(values) do
    case Integer.parse(segment) do
      {index, ""} when index >= 0 and index < length(values) -> {:ok, Enum.at(values, index)}
      _other -> :error
    end
  end

  defp fetch_pointer(_value, _segment), do: :error

  defp decode_pointer_segment(segment) do
    segment
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  defp existing_atom(segment) do
    String.to_existing_atom(segment)
  rescue
    ArgumentError -> nil
  end

  defp integer_key(segment) do
    case Integer.parse(segment) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp missing_ref(ref) do
    {:error, Error.new(:json_schema_ref_not_found, "JSON schema ref was not found", %{ref: ref})}
  end
end
