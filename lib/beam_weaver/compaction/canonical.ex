defmodule BeamWeaver.Compaction.Canonical do
  @moduledoc false

  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(value) do
    if json_value?(value) do
      {:ok, value |> encode_iodata() |> IO.iodata_to_binary()}
    else
      {:error, :invalid_json_value}
    end
  rescue
    error -> {:error, error}
  end

  @spec hash(term()) :: String.t()
  def hash(value) do
    case encode(value) do
      {:ok, bytes} -> bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
      {:error, reason} -> raise ArgumentError, "cannot canonicalize value: #{inspect(reason)}"
    end
  end

  @spec encoded_size(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def encoded_size(value) do
    case encode(value) do
      {:ok, bytes} -> {:ok, byte_size(bytes)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec json_value?(term()) :: boolean()
  def json_value?(value), do: json_value?(value, 0)

  defp json_value?(_value, depth) when depth > 32, do: false
  defp json_value?(value, _depth) when is_nil(value) or is_boolean(value), do: true
  defp json_value?(value, _depth) when is_integer(value) or is_float(value), do: true
  defp json_value?(value, _depth) when is_binary(value), do: String.valid?(value)
  defp json_value?(values, depth) when is_list(values), do: Enum.all?(values, &json_value?(&1, depth + 1))

  defp json_value?(value, depth) when is_map(value) do
    keys = Enum.map(value, fn {key, _nested} -> key_string(key) end)

    Enum.all?(value, fn {key, nested} ->
      is_binary(key_string(key)) and json_value?(nested, depth + 1)
    end) and length(keys) == length(Enum.uniq(keys))
  end

  defp json_value?(_value, _depth), do: false

  defp encode_iodata(nil), do: "null"
  defp encode_iodata(true), do: "true"
  defp encode_iodata(false), do: "false"
  defp encode_iodata(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_iodata(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp encode_iodata(value) when is_binary(value), do: BeamWeaver.JSON.encode!(value)

  defp encode_iodata(values) when is_list(values) do
    ["[", values |> Enum.map(&encode_iodata/1) |> Enum.intersperse(","), "]"]
  end

  defp encode_iodata(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} -> {key_string(key), nested} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, nested} -> [BeamWeaver.JSON.encode!(key), ":", encode_iodata(nested)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(_key), do: nil
end
