defmodule BeamWeaver.Graph.Messages do
  @moduledoc """
  LangGraph-compatible message reducers for graph state.
  """

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Channels.DeltaChannel

  @remove_all "__remove_all__"

  defmodule Remove do
    @moduledoc "Message deletion marker used by `BeamWeaver.Graph.Messages.add_messages/2`."
    @enforce_keys [:id]
    defstruct [:id]

    @type t :: %__MODULE__{id: String.t()}
  end

  @spec remove(String.t()) :: Remove.t()
  def remove(id), do: %Remove{id: id}

  @spec remove_all() :: Remove.t()
  def remove_all, do: %Remove{id: @remove_all}

  @spec state_schema(keyword()) :: map()
  def state_schema(opts \\ []), do: %{messages: channel(opts)}

  @spec channel(keyword()) :: Graph.ChannelSpec.t()
  def channel(opts \\ []) do
    Graph.channel({BinaryOperatorAggregate, &add_messages/2}, Keyword.put_new(opts, :initial, []))
  end

  @spec delta_channel(keyword()) :: Graph.ChannelSpec.t()
  def delta_channel(opts \\ []) do
    Graph.channel({DeltaChannel, &delta_reducer/2}, opts)
  end

  @spec add_messages(term(), term()) :: [Message.t()]
  def add_messages(left, right), do: add_messages(left, right, [])

  @spec add_messages(term(), term(), keyword()) :: [Message.t()]
  def add_messages(left, right, opts) do
    left = left |> message_list() |> ensure_ids()
    right = right |> message_list() |> ensure_ids()

    case Enum.find_index(right, &match?(%Remove{id: @remove_all}, &1)) do
      nil -> merge_messages(left, right)
      index -> right |> Enum.drop(index + 1) |> reject_remove_markers()
    end
    |> maybe_format(Keyword.get(opts, :format))
  end

  @spec delta_reducer([Message.t()], list()) :: [Message.t()]
  def delta_reducer(state, writes) do
    flat =
      Enum.flat_map(writes, fn
        write when is_list(write) -> write
        write -> [write]
      end)

    state_messages = state |> message_list() |> ensure_ids()
    write_messages = flat |> message_list() |> ensure_ids()

    {state_messages, write_messages} =
      case last_remove_all_index(write_messages) do
        nil -> {state_messages, write_messages}
        index -> {[], Enum.drop(write_messages, index + 1)}
      end

    {result, index} =
      Enum.reduce(Enum.with_index(state_messages), {state_messages, %{}}, fn {message, index}, {messages, acc} ->
        if is_binary(message.id),
          do: {messages, Map.put(acc, message.id, index)},
          else: {messages, acc}
      end)

    {result, _index} =
      Enum.reduce(write_messages, {result, index}, fn
        %Remove{id: id}, {messages, index} ->
          case Map.fetch(index, id) do
            {:ok, position} ->
              {List.replace_at(messages, position, nil), Map.delete(index, id)}

            :error ->
              {messages, index}
          end

        %Message{id: id} = message, {messages, index} ->
          case Map.fetch(index, id) do
            {:ok, position} -> {List.replace_at(messages, position, message), index}
            :error -> {messages ++ [message], Map.put(index, id, length(messages))}
          end
      end)

    Enum.reject(result, &is_nil/1)
  end

  @spec normalize(term()) :: Message.t() | Remove.t()
  def normalize(%Message{} = message), do: message
  def normalize(%Remove{} = remove), do: remove

  def normalize({role, content}) when role in [:system, :user, :assistant, :tool] do
    Message.new!(role, content)
  end

  def normalize({role, content}) when is_binary(role) do
    role |> role_atom() |> Message.new!(content)
  end

  def normalize(%{"type" => "remove", "id" => id}), do: remove(id)
  def normalize(%{type: :remove, id: id}), do: remove(id)

  def normalize(%{"role" => role, "content" => content} = map),
    do: message_from_map(map, role, content)

  def normalize(%{role: role, content: content} = map), do: message_from_map(map, role, content)
  def normalize(content) when is_binary(content), do: Message.user(content)

  def normalize(other) do
    raise ArgumentError, "unsupported message representation: #{inspect(other)}"
  end

  defp message_from_map(map, role, content) do
    Message.new!(role_atom(role), content,
      id: map_value(map, :id),
      name: map_value(map, :name),
      metadata: map_value(map, :metadata, %{}),
      tool_calls: map_value(map, :tool_calls, []),
      tool_call_id: map_value(map, :tool_call_id)
    )
  end

  defp message_list(nil), do: []
  defp message_list(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp message_list(message), do: [normalize(message)]

  defp ensure_ids(messages) do
    Enum.map(messages, fn
      %Message{id: nil} = message -> %{message | id: BeamWeaver.Core.ID.uuidv7()}
      message -> message
    end)
  end

  defp last_remove_all_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%Remove{id: @remove_all}, index}, _acc -> index
      _other, acc -> acc
    end)
  end

  defp merge_messages(left, right) do
    {merged, by_id, removals} =
      Enum.reduce(Enum.with_index(left), {left, %{}, MapSet.new()}, fn {message, index}, {messages, ids, removals} ->
        {messages, Map.put(ids, message.id, index), removals}
      end)

    {merged, _by_id, removals} =
      Enum.reduce(right, {merged, by_id, removals}, fn
        %Remove{id: id}, {messages, by_id, removals} ->
          if Map.has_key?(by_id, id) do
            {messages, by_id, MapSet.put(removals, id)}
          else
            raise ArgumentError,
                  "attempting to delete a message with an ID that does not exist: #{inspect(id)}"
          end

        %Message{id: id} = message, {messages, by_id, removals} ->
          case Map.fetch(by_id, id) do
            {:ok, index} ->
              {List.replace_at(messages, index, message), by_id, MapSet.delete(removals, id)}

            :error ->
              {messages ++ [message], Map.put(by_id, id, length(messages)), removals}
          end
      end)

    Enum.reject(merged, &MapSet.member?(removals, &1.id))
  end

  defp reject_remove_markers(messages) do
    Enum.reject(messages, &match?(%Remove{}, &1))
  end

  defp maybe_format(messages, nil), do: messages
  defp maybe_format(messages, :openai), do: Enum.map(messages, &format_openai/1)
  defp maybe_format(messages, "langchain-openai"), do: Enum.map(messages, &format_openai/1)

  defp maybe_format(_messages, format) do
    raise ArgumentError, "unsupported message format: #{inspect(format)}"
  end

  defp format_openai(%Message{role: :assistant, content: content} = message)
       when is_list(content) do
    {tool_calls, blocks} =
      Enum.reduce(content, {[], []}, fn
        %{"type" => "tool_use", "name" => name, "input" => input, "id" => id}, {calls, blocks} ->
          call = %{"name" => name, "type" => "tool_calls", "args" => input || %{}, "id" => id}
          {[call | calls], blocks}

        %{type: :tool_use, name: name, args: args, id: id}, {calls, blocks} ->
          call = %{"name" => name, "type" => "tool_calls", "args" => args || %{}, "id" => id}
          {[call | calls], blocks}

        block, {calls, blocks} ->
          {calls, [format_content_block(block) | blocks]}
      end)
      |> then(fn {calls, blocks} -> {Enum.reverse(calls), Enum.reverse(blocks)} end)

    %{message | content: if(blocks == [], do: "", else: blocks), tool_calls: tool_calls}
  end

  defp format_openai(%Message{role: :user, content: [%{"type" => "tool_result"} = result]} = message) do
    content =
      result
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.map(&format_content_block/1)

    Message.tool(content, id: message.id, tool_call_id: Map.get(result, "tool_use_id"))
  end

  defp format_openai(%Message{role: :user, content: [%ContentBlock.ToolResult{} = result]} = message) do
    content =
      result.content
      |> List.wrap()
      |> Enum.map(&format_content_block/1)

    Message.tool(content, id: message.id, tool_call_id: result.tool_call_id)
  end

  defp format_openai(%Message{content: content} = message) when is_list(content) do
    %{message | content: Enum.map(content, &format_content_block/1)}
  end

  defp format_openai(message), do: message

  defp format_content_block(%{"type" => "text", "text" => _text} = block), do: block

  defp format_content_block(%{type: :text, text: text} = block) do
    %{"type" => "text", "text" => text}
    |> put_if_present("cache_control", Map.get(block, :cache_control))
  end

  defp format_content_block(%{
         "type" => "image",
         "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
       }) do
    %{"type" => "image_url", "image_url" => %{"url" => "data:#{media_type};base64,#{data}"}}
  end

  defp format_content_block(%ContentBlock.Image{url: url}) when is_binary(url) do
    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  defp format_content_block(%ContentBlock.Image{data: data, mime_type: media_type})
       when is_binary(data) and is_binary(media_type) do
    %{"type" => "image_url", "image_url" => %{"url" => "data:#{media_type};base64,#{data}"}}
  end

  defp format_content_block(block), do: block

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp role_atom("human"), do: :user
  defp role_atom("user"), do: :user
  defp role_atom("ai"), do: :assistant
  defp role_atom("assistant"), do: :assistant
  defp role_atom("system"), do: :system
  defp role_atom("tool"), do: :tool
  defp role_atom(role) when role in [:system, :user, :assistant, :tool], do: role

  defp role_atom(role) do
    raise ArgumentError, "unsupported message role: #{inspect(role)}"
  end

  defp map_value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
