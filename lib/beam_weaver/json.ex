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

  @spec read!(Path.t()) :: term()
  def read!(path) do
    path
    |> File.read!()
    |> decode!()
  end

  @spec decode!(binary() | iodata()) :: term()
  def decode!(data) do
    data
    |> to_binary()
    |> Elixir.JSON.decode!()
    |> normalize_json()
  end

  @spec encode(term()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(value) do
    {:ok, encode!(value)}
  rescue
    exception -> {:error, exception}
  end

  @spec encode(term(), keyword() | function()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(value, opts_or_encoder) do
    {:ok, encode!(value, opts_or_encoder)}
  rescue
    exception -> {:error, exception}
  end

  @spec encode!(term()) :: binary()
  def encode!(value), do: Elixir.JSON.encode!(value)

  @spec encode!(term(), keyword() | function()) :: binary()
  def encode!(value, opts) when is_list(opts) do
    if Keyword.get(opts, :pretty, false) do
      value
      |> encode_pretty()
      |> IO.iodata_to_binary()
    else
      Elixir.JSON.encode!(value)
    end
  end

  def encode!(value, encoder) when is_function(encoder, 2),
    do: Elixir.JSON.encode!(value, encoder)

  @spec write!(Path.t(), term()) :: :ok
  def write!(path, value) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, [encode_pretty(value), ?\n])
  end

  @spec encode_to_iodata!(term()) :: iodata()
  def encode_to_iodata!(value), do: Elixir.JSON.encode_to_iodata!(value)

  @spec encode_to_iodata!(term(), keyword() | function()) :: iodata()
  def encode_to_iodata!(value, opts) when is_list(opts), do: encode!(value, opts)

  def encode_to_iodata!(value, encoder) when is_function(encoder, 2),
    do: Elixir.JSON.encode_to_iodata!(value, encoder)

  defp to_binary(data) when is_binary(data), do: data
  defp to_binary(data), do: IO.iodata_to_binary(data)

  defp encode_pretty(value), do: encode_pretty(value, 0)

  defp encode_pretty(nil, _indent), do: "null"
  defp encode_pretty(true, _indent), do: "true"
  defp encode_pretty(false, _indent), do: "false"
  defp encode_pretty(value, _indent) when is_integer(value), do: Integer.to_string(value)

  defp encode_pretty(value, _indent) when is_float(value),
    do: :erlang.float_to_binary(value, [:short])

  defp encode_pretty(value, _indent) when is_binary(value) do
    [?\", escape(value), ?\"]
  end

  defp encode_pretty(values, indent) when is_list(values) do
    if values == [] do
      "[]"
    else
      inner_indent = indent + 2

      [
        "[\n",
        values
        |> Enum.map(fn value -> [spaces(inner_indent), encode_pretty(value, inner_indent)] end)
        |> Enum.intersperse(",\n"),
        "\n",
        spaces(indent),
        "]"
      ]
    end
  end

  defp encode_pretty(value, indent) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, map_value} -> {to_string(key), map_value} end)
      |> Enum.sort_by(fn {key, _map_value} -> key end)

    if entries == [] do
      "{}"
    else
      inner_indent = indent + 2

      [
        "{\n",
        entries
        |> Enum.map(fn {key, map_value} ->
          [
            spaces(inner_indent),
            encode_pretty(key, inner_indent),
            ": ",
            encode_pretty(map_value, inner_indent)
          ]
        end)
        |> Enum.intersperse(",\n"),
        "\n",
        spaces(indent),
        "}"
      ]
    end
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> escape_control_chars()
  end

  defp escape_control_chars(value) do
    for <<codepoint::utf8 <- value>>, into: "" do
      case codepoint do
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

  defp spaces(0), do: ""
  defp spaces(count), do: String.duplicate(" ", count)

  defp normalize_json(nil), do: nil

  defp normalize_json(values) when is_list(values) do
    Enum.map(values, &normalize_json/1)
  end

  defp normalize_json(value) when is_map(value) do
    Map.new(value, fn {key, map_value} -> {key, normalize_json(map_value)} end)
  end

  defp normalize_json(value), do: value
end
