defmodule BeamWeaver.Tracing.Exporters.LangSmith.ValueEncoder do
  @moduledoc false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Serialization, as: MessageSerialization

  @spec encode(term()) :: term()
  def encode(value), do: do_encode(value)

  defp do_encode(nil), do: nil
  defp do_encode(value) when is_boolean(value), do: value
  defp do_encode(value) when is_integer(value), do: value
  defp do_encode(value) when is_float(value), do: value
  defp do_encode(value) when is_binary(value), do: encode_binary(value)
  defp do_encode(value) when is_atom(value), do: Atom.to_string(value)

  defp do_encode(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp do_encode(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp do_encode(%Date{} = value), do: Date.to_iso8601(value)
  defp do_encode(%Time{} = value), do: Time.to_iso8601(value)

  defp do_encode(%Message{} = message) do
    message
    |> encode_message_fields()
    |> MessageSerialization.encode()
    |> do_encode()
  end

  defp do_encode(%MapSet{} = set) do
    set
    |> MapSet.to_list()
    |> Enum.map(&do_encode/1)
  end

  defp do_encode(%Regex{} = regex), do: Regex.source(regex)
  defp do_encode(%Range{} = range), do: Enum.to_list(range)

  defp do_encode(%{__struct__: module} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put_new(:type, struct_type(module))
    |> do_encode()
  rescue
    _exception -> inspect(struct, limit: :infinity, printable_limit: :infinity)
  end

  defp do_encode(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {encode_key(key), do_encode(nested)} end)
  end

  defp do_encode(value) when is_list(value), do: Enum.map(value, &do_encode/1)

  defp do_encode(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&do_encode/1)
  end

  defp do_encode(value) when is_function(value), do: inspect(value)
  defp do_encode(value) when is_pid(value), do: inspect(value)
  defp do_encode(value) when is_port(value), do: inspect(value)
  defp do_encode(value) when is_reference(value), do: inspect(value)
  defp do_encode(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp encode_binary(value) do
    if String.valid?(value) do
      value
    else
      %{"type" => "base64", "data" => Base.encode64(value)}
    end
  end

  defp encode_key(key) when is_atom(key), do: key

  defp encode_key(key) when is_binary(key) do
    if String.valid?(key), do: key, else: "base64:" <> Base.encode64(key)
  end

  defp encode_key(key), do: inspect(key, limit: :infinity, printable_limit: :infinity)

  defp encode_message_fields(%Message{} = message) do
    %Message{
      message
      | content: do_encode(message.content),
        metadata: do_encode(message.metadata),
        response_metadata: do_encode(message.response_metadata),
        usage_metadata: do_encode(message.usage_metadata),
        artifacts: do_encode(message.artifacts),
        server_tool_calls: do_encode(message.server_tool_calls),
        server_tool_results: do_encode(message.server_tool_results),
        tool_calls: do_encode(message.tool_calls)
    }
  end

  defp struct_type(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore()
end
