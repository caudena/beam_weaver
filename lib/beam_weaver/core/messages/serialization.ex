defmodule BeamWeaver.Core.Messages.Serialization do
  @moduledoc """
  Safe plain-data serialization for messages.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.MessageLike

  @version 1

  @spec encode(Message.t()) :: map()
  def encode(%Message{} = message) do
    %{
      "version" => @version,
      "type" => "message",
      "role" => Atom.to_string(message.role),
      "content" => stringify_value(message.content),
      "id" => message.id,
      "name" => message.name,
      "metadata" => stringify_keys(message.metadata),
      "response_metadata" => stringify_keys(message.response_metadata),
      "usage_metadata" => stringify_keys(message.usage_metadata),
      "status" => encode_status(message.status),
      "artifacts" => stringify_value(message.artifacts),
      "server_tool_calls" => stringify_value(message.server_tool_calls),
      "server_tool_results" => stringify_value(message.server_tool_results),
      "tool_calls" => stringify_value(message.tool_calls),
      "tool_call_id" => message.tool_call_id
    }
    |> reject_nil_values()
  end

  @spec decode(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def decode(%{"version" => @version, "type" => "message"} = map) do
    MessageLike.to_message(%{
      role: map["role"],
      content: decode_content(map["content"]),
      id: map["id"],
      name: map["name"],
      metadata: map["metadata"] || %{},
      response_metadata: map["response_metadata"] || %{},
      usage_metadata: map["usage_metadata"],
      status: map["status"],
      artifacts: map["artifacts"] || [],
      server_tool_calls: map["server_tool_calls"] || [],
      server_tool_results: map["server_tool_results"] || [],
      tool_calls: map["tool_calls"] || [],
      tool_call_id: map["tool_call_id"]
    })
  end

  def decode(%{"type" => "message"} = map) do
    {:error,
     Error.new(:unsupported_message_version, "unsupported message version", %{
       version: map["version"]
     })}
  end

  def decode(map) when is_map(map), do: MessageLike.to_message(map)

  def decode(_value),
    do: {:error, Error.new(:invalid_message, "serialized message must be a map")}

  defp decode_content(content), do: content

  defp stringify_keys(nil), do: nil

  defp stringify_keys(%{__struct__: module} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put(:type, struct_type(module, Map.get(struct, :type)))
    |> stringify_keys()
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)

  defp stringify_keys(value), do: value

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp struct_type(_module, type) when not is_nil(type), do: type

  defp struct_type(module, _type),
    do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp encode_status(nil), do: nil
  defp encode_status(status) when is_atom(status), do: Atom.to_string(status)
  defp encode_status(status), do: status

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
