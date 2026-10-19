defmodule BeamWeaver.Core.Messages.MessageChunk do
  @moduledoc """
  Merge and finalize helpers for streamed message chunks.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.AIChunk
  alias BeamWeaver.Core.Messages.Chunk
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Messages.ToolCallChunk

  @spec merge(term(), term()) :: term()
  def merge(nil, right), do: right
  def merge(left, nil), do: left

  def merge(left, right) do
    left = normalize(left)
    right = normalize(right)

    %Chunk{
      role: left.role || right.role,
      content: merge_content(left.content, right.content),
      id: left.id || right.id,
      name: left.name || right.name,
      tool_call_id: left.tool_call_id || right.tool_call_id,
      metadata: Map.merge(left.metadata || %{}, right.metadata || %{}),
      tool_calls: (left.tool_calls || []) ++ (right.tool_calls || []),
      tool_call_chunks: merge_tool_call_chunks(left.tool_call_chunks || [], right.tool_call_chunks || []),
      invalid_tool_calls: (left.invalid_tool_calls || []) ++ (right.invalid_tool_calls || [])
    }
  end

  @spec merge_many([term()]) :: term() | nil
  def merge_many(chunks), do: Enum.reduce(chunks, nil, fn chunk, acc -> merge(acc, chunk) end)

  @spec to_message(term()) :: Message.t()
  def to_message(chunk) do
    chunk = normalize(chunk)
    role = role(chunk.role)
    {tool_calls, invalid_tool_calls} = finalized_tool_calls(chunk)

    Message.new!(role, chunk.content || "",
      id: chunk.id,
      name: chunk.name,
      metadata:
        chunk.metadata
        |> Map.put_new(:invalid_tool_calls, invalid_tool_calls)
        |> BeamWeaver.MapShape.compact([nil, :empty_list]),
      tool_calls: tool_calls,
      tool_call_id: chunk.tool_call_id
    )
  end

  defp normalize(%AIChunk{} = chunk), do: struct(Chunk, Map.from_struct(chunk))
  defp normalize(%Chunk{} = chunk), do: chunk

  defp normalize(%Message{} = message) do
    %Chunk{
      role: message.role,
      content: message.content,
      id: message.id,
      name: message.name,
      metadata: message.metadata,
      tool_calls: message.tool_calls,
      tool_call_id: message.tool_call_id
    }
  end

  defp role(:function), do: :assistant
  defp role(role) when role in [:system, :user, :assistant, :tool], do: role
  defp role(_role), do: :assistant

  defp merge_content(left, right) when is_binary(left) and is_binary(right), do: left <> right
  defp merge_content(nil, right), do: right
  defp merge_content(left, nil), do: left

  defp merge_content(left, right) when is_list(left) and is_list(right),
    do: Enum.reduce(right, left, &append_content_item(&2, &1))

  defp merge_content(left, right) when is_list(left), do: append_content_item(left, right)
  defp merge_content("", right) when is_list(right), do: right
  defp merge_content(left, right) when is_list(right), do: [left | right]
  defp merge_content(left, right), do: to_string(left || "") <> to_string(right || "")

  defp merge_tool_call_chunks(left, right) do
    (left ++ right)
    |> Enum.map(&normalize_tool_call_chunk/1)
    |> Enum.reduce([], &merge_tool_chunk/2)
    |> Enum.sort_by(&(&1.index || 0))
  end

  defp normalize_tool_call_chunk(%ToolCallChunk{} = chunk), do: chunk

  defp normalize_tool_call_chunk(%{} = chunk) do
    %ToolCallChunk{
      id: Map.get(chunk, :id),
      index: Map.get(chunk, :index),
      name: Map.get(chunk, :name),
      args: Map.get(chunk, :args, ""),
      type: Map.get(chunk, :type, :tool_call_chunk)
    }
  end

  defp merge_tool_chunk(%ToolCallChunk{} = chunk, acc) do
    case Enum.find_index(acc, &mergeable_tool_chunks?(&1, chunk)) do
      nil ->
        acc ++ [chunk]

      index ->
        List.update_at(acc, index, &combine_tool_chunks(&1, chunk))
    end
  end

  defp mergeable_tool_chunks?(%ToolCallChunk{id: left_id}, %ToolCallChunk{id: right_id})
       when not is_nil(left_id) and not is_nil(right_id),
       do: left_id == right_id

  defp mergeable_tool_chunks?(
         %ToolCallChunk{index: index, id: left_id},
         %ToolCallChunk{index: index, id: right_id}
       )
       when not is_nil(index),
       do: is_nil(left_id) or is_nil(right_id) or left_id == right_id

  defp mergeable_tool_chunks?(_left, _right), do: false

  defp combine_tool_chunks(left, right) do
    %ToolCallChunk{
      id: left.id || right.id,
      index: left.index || right.index,
      name: left.name || right.name,
      args: to_string(left.args || "") <> to_string(right.args || "")
    }
  end

  defp append_content_item(acc, ""), do: acc

  defp append_content_item(acc, item) when is_binary(item) do
    case List.last(acc) do
      last when is_binary(last) ->
        List.update_at(acc, -1, &(&1 <> item))

      _other ->
        acc ++ [item]
    end
  end

  defp append_content_item(acc, item) when is_map(item) do
    case Enum.find_index(acc, &mergeable_content_blocks?(&1, item)) do
      nil ->
        acc ++ [item]

      index ->
        List.update_at(acc, index, &merge_content_block(&1, item))
    end
  end

  defp append_content_item(acc, item), do: acc ++ [item]

  defp mergeable_content_blocks?(left, right) when is_map(left) and is_map(right) do
    left_index = Map.get(left, :index)
    right_index = Map.get(right, :index)

    not is_nil(left_index) and left_index == right_index and
      (text_content_blocks?(left, right) or reasoning_content_blocks?(left, right))
  end

  defp mergeable_content_blocks?(_left, _right), do: false

  defp merge_content_block(left, right) do
    left_type = Map.get(left, :type)
    text = to_string(Map.get(left, :text) || "") <> to_string(Map.get(right, :text) || "")

    reasoning =
      to_string(Map.get(left, :reasoning) || "") <>
        to_string(Map.get(right, :reasoning) || "")

    raw_provider_block =
      merge_provider_blocks(Map.get(left, :raw_provider_block), Map.get(right, :raw_provider_block))

    left
    |> Map.merge(right)
    |> map_put_existing_key(left, :text, text)
    |> map_put_if_present(left, right, :reasoning, reasoning)
    |> BeamWeaver.MapShape.put_present(:raw_provider_block, raw_provider_block)
    |> BeamWeaver.MapShape.put_present(:type, left_type)
  end

  defp text_content_blocks?(left, right),
    do: is_binary(Map.get(left, :text)) or is_binary(Map.get(right, :text))

  defp reasoning_content_blocks?(left, right) do
    reasoning_block?(left) and reasoning_block?(right)
  end

  defp reasoning_block?(block), do: Map.get(block, :type) in [:reasoning, "reasoning"]

  defp map_put_if_present(map, left, right, key, value) do
    if Map.has_key?(left, key) or Map.has_key?(right, key), do: Map.put(map, key, value), else: map
  end

  defp merge_provider_blocks(left, right) when is_map(left) and is_map(right) do
    type = Map.get(left, "type") || Map.get(left, :type)

    thinking =
      to_string(Map.get(left, "thinking") || Map.get(left, :thinking) || "") <>
        to_string(Map.get(right, "thinking") || Map.get(right, :thinking) || "")

    left
    |> Map.merge(right)
    |> put_provider_type(type)
    |> put_provider_thinking(left, right, thinking)
  end

  defp merge_provider_blocks(left, nil) when is_map(left), do: left
  defp merge_provider_blocks(nil, right) when is_map(right), do: right
  defp merge_provider_blocks(_left, _right), do: nil

  defp put_provider_type(map, nil), do: map

  defp put_provider_type(map, type) do
    cond do
      Map.has_key?(map, "type") -> Map.put(map, "type", type)
      Map.has_key?(map, :type) -> Map.put(map, :type, type)
      true -> map
    end
  end

  defp put_provider_thinking(map, left, right, thinking) do
    cond do
      Map.has_key?(left, "thinking") or Map.has_key?(right, "thinking") ->
        Map.put(map, "thinking", thinking)

      Map.has_key?(left, :thinking) or Map.has_key?(right, :thinking) ->
        Map.put(map, :thinking, thinking)

      true ->
        map
    end
  end

  defp map_put_existing_key(map, template, key, value) do
    if Map.has_key?(template, key), do: Map.put(map, key, value), else: map
  end

  defp finalized_tool_calls(%Chunk{} = chunk) do
    explicit_invalid_keys = MapSet.new(List.wrap(chunk.invalid_tool_calls), &invalid_tool_call_key/1)

    results =
      for tool_call_chunk <- chunk.tool_call_chunks || [],
          not stale_tool_chunk?(tool_call_chunk, explicit_invalid_keys),
          do: finalize_tool_call(tool_call_chunk)

    {(chunk.tool_calls || []) ++ for({:ok, tool_call} <- results, do: tool_call),
     (chunk.invalid_tool_calls || []) ++ for({:error, invalid_call} <- results, do: invalid_call)}
  end

  defp finalize_tool_call(%ToolCallChunk{} = chunk) do
    case decode_args(chunk.args) do
      {:ok, args} ->
        {:ok,
         %ToolCall{
           id: chunk.id,
           provider_id: chunk.id,
           call_id: chunk.id,
           name: chunk.name,
           args: args
         }}

      {:error, error} ->
        {:error,
         %InvalidToolCall{
           id: chunk.id,
           name: chunk.name,
           args: chunk.args,
           error: error
         }}
    end
  end

  defp stale_tool_chunk?(%ToolCallChunk{id: id, name: name, index: index}, invalid_keys) do
    Enum.any?([id, name, index], &(not is_nil(&1) and MapSet.member?(invalid_keys, &1)))
  end

  defp invalid_tool_call_key(%{id: id}) when not is_nil(id), do: id
  defp invalid_tool_call_key(%{name: name}) when not is_nil(name), do: name
  defp invalid_tool_call_key(_invalid), do: nil

  defp decode_args(""), do: {:ok, %{}}

  defp decode_args(args) when is_binary(args) or is_map(args) or is_nil(args),
    do: BeamWeaver.Core.ToolCallParser.decode_tool_args(args)

  defp decode_args(args), do: {:error, "tool call arguments are not decodable: #{inspect(args)}"}
end
