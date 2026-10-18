defmodule BeamWeaver.Tracing.ValueEncoder do
  @moduledoc false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Serialization, as: MessageSerialization

  @spec encode(term()) :: term()
  def encode(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value

  def encode(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: %{"type" => "base64", "data" => Base.encode64(value)})

  def encode(value) when is_atom(value), do: Atom.to_string(value)

  def encode(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def encode(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def encode(%Date{} = value), do: Date.to_iso8601(value)
  def encode(%Time{} = value), do: Time.to_iso8601(value)

  def encode(%Message{} = message) do
    %Message{
      message
      | content: encode(message.content),
        metadata: encode(message.metadata),
        response_metadata: encode(message.response_metadata),
        usage_metadata: encode(message.usage_metadata),
        artifacts: encode(message.artifacts),
        server_tool_calls: encode(message.server_tool_calls),
        server_tool_results: encode(message.server_tool_results),
        tool_calls: encode(message.tool_calls)
    }
    |> MessageSerialization.encode()
    |> encode()
  end

  def encode(%MapSet{} = set), do: Enum.map(set, &encode/1)

  def encode(%Regex{} = regex), do: Regex.source(regex)
  def encode(%Range{} = range), do: Enum.to_list(range)

  def encode(%{__struct__: module} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put_new(:type, module |> Module.split() |> List.last() |> Macro.underscore())
    |> encode()
  rescue
    _exception -> inspect(struct, limit: :infinity, printable_limit: :infinity)
  end

  def encode(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {encode_key(key), encode(nested)} end)
  end

  def encode(value) when is_list(value), do: Enum.map(value, &encode/1)

  def encode(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&encode/1)

  def encode(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp encode_key(key) when is_atom(key), do: key

  defp encode_key(key) when is_binary(key) do
    if String.valid?(key), do: key, else: "base64:" <> Base.encode64(key)
  end

  defp encode_key(key), do: inspect(key, limit: :infinity, printable_limit: :infinity)
end
