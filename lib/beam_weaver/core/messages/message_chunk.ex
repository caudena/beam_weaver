defmodule BeamWeaver.Core.Messages.MessageChunk do
  @moduledoc """
  Merge and finalize helpers for streamed message chunks.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.AIChunk
  alias BeamWeaver.Core.Messages.Chunk
  alias BeamWeaver.Core.Messages.FunctionChunk
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Messages.ToolCallChunk
  alias BeamWeaver.Core.Messages.ToolChunk

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
        |> reject_empty_metadata(),
      tool_calls: tool_calls,
      tool_call_id: chunk.tool_call_id
    )
  end

  defp normalize(%AIChunk{} = chunk), do: struct(Chunk, Map.from_struct(chunk))
  defp normalize(%ToolChunk{} = chunk), do: struct(Chunk, Map.from_struct(chunk))
  defp normalize(%FunctionChunk{} = chunk), do: struct(Chunk, Map.from_struct(chunk))
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
    do: merge_content_lists(left, right)

  defp merge_content(left, "") when is_list(left), do: left
  defp merge_content(left, right) when is_list(left), do: append_content_item(left, right)
  defp merge_content("", right) when is_list(right), do: right
  defp merge_content(left, right) when is_list(right), do: [left | right]
  defp merge_content(left, right), do: to_string(left || "") <> to_string(right || "")

  defp merge_tool_call_chunks(left, right) do
    (left ++ right)
    |> Enum.map(&normalize_tool_call_chunk/1)
    |> Enum.reduce([], &merge_tool_chunk/2)
    |> Enum.with_index()
    |> Enum.sort_by(fn {chunk, order} -> {chunk.index || 0, order} end)
    |> Enum.map(&elem(&1, 0))
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
        List.update_at(acc, index, &combine_tool_chunks([&1, chunk]))
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

  defp combine_tool_chunks(chunks) do
    Enum.reduce(chunks, %ToolCallChunk{}, fn chunk, %ToolCallChunk{} = acc ->
      %ToolCallChunk{
        acc
        | id: acc.id || chunk.id,
          index: acc.index || chunk.index,
          name: acc.name || chunk.name,
          args: to_string(acc.args || "") <> to_string(chunk.args || "")
      }
    end)
  end

  defp merge_content_lists(left, right) do
    Enum.reduce(right, left, &append_content_item(&2, &1))
  end

  defp append_content_item(acc, ""), do: acc

  defp append_content_item(acc, item) when is_binary(item) do
    case List.last(acc) do
      last when is_binary(last) ->
        List.update_at(acc, -1, &(to_string(&1) <> item))

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
      (is_binary(Map.get(left, :text)) or is_binary(Map.get(right, :text)))
  end

  defp mergeable_content_blocks?(_left, _right), do: false

  defp merge_content_block(left, right) do
    left_type = Map.get(left, :type)
    text = to_string(Map.get(left, :text) || "") <> to_string(Map.get(right, :text) || "")

    left
    |> Map.merge(right)
    |> map_put_existing_key(left, :text, text)
    |> maybe_preserve_content_type(left_type)
  end

  defp map_put_existing_key(map, template, key, value) do
    if Map.has_key?(template, key), do: Map.put(map, key, value), else: map
  end

  defp maybe_preserve_content_type(map, nil), do: map

  defp maybe_preserve_content_type(map, left_type) do
    if Map.has_key?(map, :type), do: Map.put(map, :type, left_type), else: map
  end

  defp finalized_tool_calls(%Chunk{} = chunk) do
    explicit_invalid_keys =
      chunk.invalid_tool_calls
      |> List.wrap()
      |> Enum.map(&invalid_tool_call_key/1)
      |> MapSet.new()

    {tool_calls, invalid_tool_calls} =
      (chunk.tool_call_chunks || [])
      |> Enum.reject(&stale_tool_chunk?(&1, explicit_invalid_keys))
      |> Enum.reduce({[], []}, fn tool_call_chunk, {valid, invalid} ->
        case finalize_tool_call(tool_call_chunk) do
          {:ok, tool_call} -> {[tool_call | valid], invalid}
          {:error, invalid_call} -> {valid, [invalid_call | invalid]}
        end
      end)

    {(chunk.tool_calls || []) ++ Enum.reverse(tool_calls),
     (chunk.invalid_tool_calls || []) ++ Enum.reverse(invalid_tool_calls)}
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

  defp invalid_tool_call_key(%InvalidToolCall{id: id}) when not is_nil(id), do: id
  defp invalid_tool_call_key(%InvalidToolCall{name: name}) when not is_nil(name), do: name
  defp invalid_tool_call_key(%{id: id}) when not is_nil(id), do: id
  defp invalid_tool_call_key(%{name: name}) when not is_nil(name), do: name
  defp invalid_tool_call_key(_invalid), do: nil

  defp decode_args(args) when is_map(args), do: {:ok, args}
  defp decode_args(nil), do: {:ok, %{}}
  defp decode_args(""), do: {:ok, %{}}

  defp decode_args(args) when is_binary(args) do
    case BeamWeaver.JSON.decode(args) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, decoded} ->
        {:error, "tool call arguments decoded to #{inspect(decoded)}, expected an object"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp decode_args(args), do: {:error, "tool call arguments are not decodable: #{inspect(args)}"}

  defp reject_empty_metadata(metadata) do
    Enum.reduce(metadata, %{}, fn
      {_key, []}, acc -> acc
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
