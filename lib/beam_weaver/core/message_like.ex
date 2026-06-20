defprotocol BeamWeaver.Core.MessageLike do
  @moduledoc """
  Converts message-like values to `%BeamWeaver.Core.Message{}`.
  """

  @fallback_to_any true

  @spec to_message(term()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, BeamWeaver.Core.Error.t()}
  def to_message(value)
end

defimpl BeamWeaver.Core.MessageLike, for: BeamWeaver.Core.Message do
  def to_message(message), do: {:ok, message}
end

defimpl BeamWeaver.Core.MessageLike, for: BitString do
  def to_message(content), do: {:ok, BeamWeaver.Core.Message.user(content)}
end

defimpl BeamWeaver.Core.MessageLike, for: Tuple do
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  def to_message({role, content}) do
    {role, opts} = role(role)
    Message.new(role, content, opts)
  end

  def to_message(tuple) do
    {:error,
     Error.new(:invalid_message, "tuple messages must be {role, content}", %{
       tuple: inspect(tuple)
     })}
  end

  defp role("developer"), do: {:system, [metadata: %{openai_role: :developer}]}
  defp role("human"), do: {:user, []}
  defp role("user"), do: {:user, []}
  defp role("ai"), do: {:assistant, []}
  defp role("assistant"), do: {:assistant, []}
  defp role("system"), do: {:system, []}
  defp role("tool"), do: {:tool, []}
  defp role("function"), do: {:assistant, []}
  defp role(role), do: {role, []}
end

defimpl BeamWeaver.Core.MessageLike, for: Map do
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.MapAccess

  def to_message(map) do
    map = maybe_unwrap_lc_envelope(map)
    role = MapAccess.get(map, :role) || MapAccess.get(map, :type)

    if MapAccess.has_key?(map, :content) do
      {role, role_opts} = role(role)
      content = normalize_content(role, MapAccess.get(map, :content))
      additional = MapAccess.get(map, :additional_kwargs) || %{}
      artifacts = artifacts(MapAccess.get(map, :artifacts), additional)
      {tool_calls, invalid_tool_calls} = normalize_tool_calls(MapAccess.get(map, :tool_calls) || [])

      metadata =
        MapAccess.get(map, :metadata)
        |> merge_metadata(additional, map)
        |> put_invalid_tool_calls(invalid_tool_calls)

      Message.new(
        role,
        content,
        Keyword.merge(
          [
            id: MapAccess.get(map, :id),
            name: MapAccess.get(map, :name),
            metadata: metadata,
            response_metadata: MapAccess.get(map, :response_metadata) || %{},
            usage_metadata: MapAccess.get(map, :usage_metadata),
            status: MapAccess.get(map, :status),
            artifacts: artifacts,
            server_tool_calls: MapAccess.get(map, :server_tool_calls) || [],
            server_tool_results: MapAccess.get(map, :server_tool_results) || [],
            tool_calls: tool_calls,
            tool_call_id: MapAccess.get(map, :tool_call_id)
          ],
          role_opts,
          fn
            :metadata, left, right -> Map.merge(left, right)
            _key, _left, right -> right
          end
        )
      )
    else
      {:error,
       Error.new(:invalid_message, "message maps must include role/type and content", %{
         map: inspect(map)
       })}
    end
  rescue
    exception ->
      {:error,
       Error.new(:invalid_message, "map could not be converted to a message", %{
         reason: Exception.message(exception)
       })}
  end

  defp normalize_content(:assistant, nil), do: ""
  defp normalize_content(_role, nil), do: ""
  defp normalize_content(_role, content), do: content

  defp maybe_unwrap_lc_envelope(%{} = map) do
    class_name = map |> MapAccess.get(:id) |> lc_envelope_class()

    if MapAccess.get(map, :lc) == 1 and MapAccess.get(map, :type) == "constructor" and
         is_binary(class_name) and is_map(MapAccess.get(map, :kwargs)) do
      case lc_envelope_role(class_name) do
        nil ->
          map

        {role, extra_metadata} ->
          kwargs = MapAccess.get(map, :kwargs)

          kwargs
          |> put_new_string("role", role)
          |> put_metadata(extra_metadata)
      end
    else
      map
    end
  end

  defp lc_envelope_class(id) when is_list(id), do: List.last(id)
  defp lc_envelope_class(_id), do: nil

  defp lc_envelope_role(class_name) when class_name in ["HumanMessage", "HumanMessageChunk"],
    do: {"human", %{}}

  defp lc_envelope_role(class_name) when class_name in ["AIMessage", "AIMessageChunk"],
    do: {"ai", %{}}

  defp lc_envelope_role(class_name) when class_name in ["SystemMessage", "SystemMessageChunk"],
    do: {"system", %{}}

  defp lc_envelope_role(class_name) when class_name in ["ToolMessage", "ToolMessageChunk"],
    do: {"tool", %{}}

  defp lc_envelope_role(class_name)
       when class_name in ["FunctionMessage", "FunctionMessageChunk"],
       do: {"ai", %{}}

  defp lc_envelope_role(_class_name), do: nil

  defp put_new_string(map, key, value) do
    if BeamWeaver.MapAccess.has_key?(map, key) do
      map
    else
      Map.put(map, key, value)
    end
  end

  defp put_metadata(map, extra) when extra == %{}, do: map

  defp role("developer"), do: {:system, [metadata: %{openai_role: :developer}]}
  defp role("human"), do: {:user, []}
  defp role("user"), do: {:user, []}
  defp role("ai"), do: {:assistant, []}
  defp role("assistant"), do: {:assistant, []}
  defp role("system"), do: {:system, []}
  defp role("tool"), do: {:tool, []}
  defp role("function"), do: {:assistant, []}
  defp role(role), do: {role, []}

  defp merge_metadata(metadata, additional, map) do
    (metadata || %{})
    |> Map.merge(additional || %{})
    |> maybe_put_refusal(map)
  end

  defp maybe_put_refusal(metadata, map) do
    case MapAccess.get(map, :refusal) do
      nil -> metadata
      refusal -> Map.put(metadata, :refusal, refusal)
    end
  end

  defp put_invalid_tool_calls(metadata, []), do: metadata

  defp put_invalid_tool_calls(metadata, invalid_tool_calls) do
    Map.put(metadata, :invalid_tool_calls, invalid_tool_calls)
  end

  defp artifacts(nil, additional), do: artifact_from_additional(additional)
  defp artifacts(artifacts, _additional) when is_list(artifacts), do: artifacts
  defp artifacts(artifact, _additional), do: [artifact]

  defp artifact_from_additional(additional) when is_map(additional) do
    case MapAccess.get(additional, :artifact) do
      nil -> []
      artifact -> [artifact]
    end
  end

  defp artifact_from_additional(_additional), do: []

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.reduce(tool_calls, {[], []}, fn call, {valid, invalid} ->
      case normalize_tool_call(call) do
        {:ok, tool_call} -> {[tool_call | valid], invalid}
        {:error, invalid_call} -> {valid, [invalid_call | invalid]}
      end
    end)
    |> then(fn {valid, invalid} -> {Enum.reverse(valid), Enum.reverse(invalid)} end)
  end

  defp normalize_tool_calls(_tool_calls), do: {[], []}

  defp normalize_tool_call(%{"type" => "function", "function" => function} = call)
       when is_map(function),
       do: BeamWeaver.Core.ToolCallParser.normalize_openai_call(call, :atom_keys)

  defp normalize_tool_call(%{type: :function, function: function} = call) when is_map(function),
    do: BeamWeaver.Core.ToolCallParser.normalize_openai_call(call, :atom_keys)

  defp normalize_tool_call(call),
    do: BeamWeaver.Core.ToolCallParser.normalize_openai_call(call, :atom_keys)
end

defimpl BeamWeaver.Core.MessageLike, for: Any do
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Messages

  def to_message(%Messages.System{} = message), do: {:ok, Messages.to_message(message)}
  def to_message(%Messages.User{} = message), do: {:ok, Messages.to_message(message)}
  def to_message(%Messages.Assistant{} = message), do: {:ok, Messages.to_message(message)}
  def to_message(%Messages.Tool{} = message), do: {:ok, Messages.to_message(message)}
  def to_message(%Messages.Function{} = message), do: {:ok, Messages.to_message(message)}
  def to_message(%Messages.Chat{} = message), do: {:ok, Messages.to_message(message)}

  def to_message(value) do
    {:error,
     Error.new(:invalid_message, "value cannot be converted to a message", %{
       value: inspect(value)
     })}
  end
end
