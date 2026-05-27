defmodule BeamWeaver.Prompt.Loader.Codec do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result

  @json_exts [".json"]
  @yaml_exts [".yaml", ".yml"]

  def decode(path, contents) do
    cond do
      Path.extname(path) in @json_exts ->
        case BeamWeaver.JSON.decode(contents) do
          {:ok, value} ->
            {:ok, value}

          {:error, error} ->
            {:error,
             Error.new(:invalid_prompt_spec, "prompt JSON could not be parsed", %{
               path: path,
               reason: Exception.message(error)
             })}
        end

      Path.extname(path) in @yaml_exts ->
        parse_yaml(path, contents)

      true ->
        {:error, Error.new(:unsupported_prompt_format, "prompt files must be JSON or YAML", %{path: path})}
    end
  end

  def encode(path, value, _opts) do
    cond do
      Path.extname(path) in @json_exts and Path.extname(resolve_existing_path(path)) in @json_exts ->
        {:ok, BeamWeaver.JSON.encode!(value, pretty: true)}

      Path.extname(path) in @yaml_exts and Path.extname(resolve_existing_path(path)) in @yaml_exts ->
        {:ok, IO.iodata_to_binary(encode_yaml(value, 0))}

      true ->
        {:error,
         Error.new(:unsupported_prompt_format, "prompt files must be saved as JSON or YAML", %{
           path: path
         })}
    end
  end

  def json_value(value) when is_map(value) do
    value
    |> Result.traverse(fn {key, map_value} ->
      with {:ok, normalized} <- json_value(map_value) do
        {:ok, {Kernel.to_string(key), normalized}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Map.new(entries)}
      error -> error
    end
  end

  def json_value(values) when is_list(values) do
    Result.traverse(values, &json_value/1)
  end

  def json_value(value)
      when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
             is_nil(value),
      do: {:ok, value}

  def json_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  def json_value(value) do
    {:error,
     Error.new(:unsupported_prompt_spec, "prompt specs must contain JSON-compatible values", %{
       value: inspect(value)
     })}
  end

  def resolve_existing_path(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} ->
            if Path.type(target) == :absolute do
              Path.expand(target)
            else
              path |> Path.dirname() |> Path.join(target) |> Path.expand()
            end

          {:error, _reason} ->
            path
        end

      _other ->
        path
    end
  end

  defp parse_yaml(path, contents) do
    documents = :yamerl_constr.string(String.to_charlist(contents))

    case documents do
      [document] ->
        {:ok, normalize_yaml(document)}

      _other ->
        {:error,
         Error.new(:invalid_prompt_spec, "prompt YAML must contain exactly one document", %{
           path: path
         })}
    end
  rescue
    error ->
      {:error,
       Error.new(:invalid_prompt_spec, "prompt YAML could not be parsed", %{
         path: path,
         reason: Exception.message(error)
       })}
  end

  defp encode_yaml(value, indent) when is_map(value) and map_size(value) == 0,
    do: [spaces(indent), "{}"]

  defp encode_yaml(value, indent) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, map_value} ->
      if scalar_yaml?(map_value) do
        [spaces(indent), key, ": ", yaml_scalar(map_value), "\n"]
      else
        [spaces(indent), key, ":\n", encode_yaml(map_value, indent + 2)]
      end
    end)
  end

  defp encode_yaml([], indent), do: [spaces(indent), "[]"]

  defp encode_yaml(values, indent) when is_list(values) do
    Enum.map(values, fn value ->
      if scalar_yaml?(value) do
        [spaces(indent), "- ", yaml_scalar(value), "\n"]
      else
        [spaces(indent), "-\n", encode_yaml(value, indent + 2)]
      end
    end)
  end

  defp scalar_yaml?(value),
    do:
      is_nil(value) or is_binary(value) or is_integer(value) or is_float(value) or
        is_boolean(value) or value == [] or value == %{}

  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(true), do: "true"
  defp yaml_scalar(false), do: "false"
  defp yaml_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_scalar(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp yaml_scalar([]), do: "[]"
  defp yaml_scalar(value) when is_map(value) and map_size(value) == 0, do: "{}"
  defp yaml_scalar(value) when is_binary(value), do: BeamWeaver.JSON.encode!(value)

  defp normalize_yaml(value) when is_list(value) do
    cond do
      printable_charlist?(value) ->
        List.to_string(value)

      keywordish?(value) ->
        Map.new(value, fn {key, map_value} ->
          {Kernel.to_string(key), normalize_yaml(map_value)}
        end)

      true ->
        Enum.map(value, &normalize_yaml/1)
    end
  end

  defp normalize_yaml(value) when is_binary(value), do: value
  defp normalize_yaml(value) when is_integer(value), do: value
  defp normalize_yaml(value) when is_float(value), do: value
  defp normalize_yaml(true), do: true
  defp normalize_yaml(false), do: false
  defp normalize_yaml(:null), do: nil
  defp normalize_yaml(value) when is_atom(value), do: Kernel.to_string(value)

  defp keywordish?(values), do: Enum.all?(values, &match?({_key, _value}, &1))
  defp printable_charlist?(values), do: values != [] and Enum.all?(values, &is_integer/1)

  defp spaces(0), do: ""
  defp spaces(count), do: String.duplicate(" ", count)
end
