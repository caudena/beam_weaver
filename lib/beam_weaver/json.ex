defmodule BeamWeaver.JSON do
  @moduledoc false

  defmodule DecodeError do
    @moduledoc false

    defexception [:reason]

    @type t :: %__MODULE__{reason: term()}

    @impl true
    def message(%__MODULE__{reason: {:invalid_byte, offset, byte}}),
      do: "unexpected byte #{inspect(<<byte>>)} at offset #{offset}"

    def message(%__MODULE__{reason: {:unexpected_end, offset}}),
      do: "unexpected end of JSON input at offset #{offset}"

    def message(%__MODULE__{reason: reason}),
      do: "unexpected JSON decode error: #{inspect(reason)}"
  end

  @spec decode(binary() | iodata()) :: {:ok, term()} | {:error, DecodeError.t()}
  def decode(data) do
    case Elixir.JSON.decode(to_binary(data)) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, %DecodeError{reason: reason}}
    end
  end

  @spec decode!(binary() | iodata()) :: term()
  def decode!(data), do: data |> to_binary() |> Elixir.JSON.decode!()

  @spec encode(term()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(value) do
    {:ok, encode!(value)}
  rescue
    exception -> {:error, exception}
  end

  @spec encode_or_inspect(term()) :: String.t()
  def encode_or_inspect(value) do
    case encode(value) do
      {:ok, json} -> json
      {:error, _error} -> inspect(value)
    end
  end

  @spec encode!(term(), keyword()) :: binary()
  def encode!(value, opts \\ []) when is_list(opts) do
    if Keyword.get(opts, :pretty, false) do
      value
      |> encode_pretty(0)
      |> IO.iodata_to_binary()
    else
      Elixir.JSON.encode!(value)
    end
  end

  defp to_binary(data) when is_binary(data), do: data
  defp to_binary(data), do: IO.iodata_to_binary(data)

  defp encode_pretty(nil, _indent), do: "null"
  defp encode_pretty(true, _indent), do: "true"
  defp encode_pretty(false, _indent), do: "false"
  defp encode_pretty(value, _indent) when is_integer(value), do: Integer.to_string(value)

  defp encode_pretty(value, _indent) when is_float(value),
    do: :erlang.float_to_binary(value, [:short])

  defp encode_pretty(value, _indent) when is_binary(value) do
    [?\", escape(value), ?\"]
  end

  defp encode_pretty([], _indent), do: "[]"

  defp encode_pretty(values, indent) when is_list(values),
    do: values |> Enum.map(&encode_pretty(&1, indent + 2)) |> pretty_container("[", "]", indent)

  defp encode_pretty(%_{} = struct, _indent), do: Elixir.JSON.encode!(struct)
  defp encode_pretty(value, _indent) when value == %{}, do: "{}"

  defp encode_pretty(value, indent) when is_map(value) do
    value
    |> Enum.map(fn {key, map_value} -> {to_string(key), map_value} end)
    |> Enum.sort_by(fn {key, _map_value} -> key end)
    |> Enum.map(fn {key, map_value} -> [encode_pretty(key, indent), ": ", encode_pretty(map_value, indent + 2)] end)
    |> pretty_container("{", "}", indent)
  end

  defp encode_pretty(value, _indent), do: Elixir.JSON.encode!(value)

  defp escape(value) do
    for <<codepoint::utf8 <- value>>, into: "" do
      case codepoint do
        ?\\ -> "\\\\"
        ?" -> "\\\""
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        ?\b -> "\\b"
        ?\f -> "\\f"
        c when c < 0x20 -> "\\u" <> (c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
        c -> <<c::utf8>>
      end
    end
  end

  defp pretty_container(items, open, close, indent) do
    inner_spaces = spaces(indent + 2)
    [open, "\n", Enum.map_intersperse(items, ",\n", &[inner_spaces, &1]), "\n", spaces(indent), close]
  end

  defp spaces(count), do: String.duplicate(" ", count)
end
