defmodule BeamWeaver.YAML do
  @moduledoc false

  # Decodes YAML with yamerl into plain terms: strings come back as binaries,
  # mappings as maps, `null` as `nil`, and numbers and booleans as themselves,
  # so `""`, `[]` and a list of integers stay apart.

  @doc false
  # Decodes a string that holds exactly one YAML document.
  #
  # Options:
  #
  #   * `:string_keys` - turns every mapping key into a string, so `1:` is
  #     `"1"`. Without it a key keeps its YAML type.
  #   * `:unique_keys` - rejects a mapping that repeats a key, at any depth.
  #     Without it the last value wins.
  @spec decode(String.t(), keyword()) ::
          {:ok, term()} | {:error, :not_one_document | :duplicate_keys | {:invalid, String.t()}}
  def decode(yaml, opts \\ []) when is_binary(yaml) do
    with :ok <- check_unique_keys(yaml, Keyword.get(opts, :unique_keys, false)),
         [document] <- parse(yaml, map_node_format: :map) do
      {:ok, normalize(document, Keyword.get(opts, :string_keys, false))}
    else
      {:error, _reason} = error -> error
      _documents -> {:error, :not_one_document}
    end
  rescue
    error -> {:error, {:invalid, Exception.message(error)}}
  catch
    # yamerl throws its parse errors.
    :throw, {:yamerl_exception, errors} -> {:error, {:invalid, inspect(errors)}}
  end

  defp parse(yaml, opts), do: :yamerl_constr.string(String.to_charlist(yaml), [str_node_as_binary: true] ++ opts)

  # yamerl keeps a repeated key only in its key-value lists, so the check
  # reads the YAML in that form; the value comes from the map form, where an
  # empty mapping and an empty sequence stay apart.
  defp check_unique_keys(_yaml, false), do: :ok

  defp check_unique_keys(yaml, true) do
    case parse(yaml, keep_duplicate_keys: true) do
      [document] -> if unique_keys?(document), do: :ok, else: {:error, :duplicate_keys}
      _documents -> {:error, :not_one_document}
    end
  end

  defp normalize(value, string_keys?) when is_map(value), do: normalize_mapping(value, string_keys?)

  defp normalize(value, string_keys?) when is_list(value), do: Enum.map(value, &normalize(&1, string_keys?))

  defp normalize(:null, _string_keys?), do: nil
  defp normalize(value, _string_keys?) when is_atom(value) and not is_boolean(value), do: Atom.to_string(value)
  defp normalize(value, _string_keys?), do: value

  defp normalize_mapping(pairs, string_keys?) do
    Map.new(pairs, fn {key, value} -> {normalize_key(key, string_keys?), normalize(value, string_keys?)} end)
  end

  defp normalize_key(key, true), do: to_string(key)
  defp normalize_key(key, false), do: key

  # In the key-value form a list is a mapping's pairs or a sequence: no other
  # node decodes to a tuple.
  defp mapping?(value), do: value != [] and Enum.all?(value, &match?({_key, _value}, &1))

  defp unique_keys?(value) when is_list(value) do
    {keys, children} = if mapping?(value), do: Enum.unzip(value), else: {[], value}
    length(keys) == MapSet.size(MapSet.new(keys)) and Enum.all?(children, &unique_keys?/1)
  end

  defp unique_keys?(_value), do: true
end
