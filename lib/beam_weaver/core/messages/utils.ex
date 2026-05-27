defmodule BeamWeaver.Core.Messages.Utils do
  @moduledoc """
  Message filtering, merging, trimming, and counting helpers.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.MessageLike
  alias BeamWeaver.Core.Messages.Buffer
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.Core.Messages.OpenAI
  alias BeamWeaver.Core.Messages.Serialization
  alias BeamWeaver.Core.Messages.TokenCounter
  alias BeamWeaver.Core.Messages.Trim
  alias BeamWeaver.Core.Messages.Usage
  alias BeamWeaver.Result

  @doc """
  Converts a list of message-like values to messages.
  """
  @spec normalize(term()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def normalize(messages) when is_list(messages) do
    Result.traverse(messages, &MessageLike.to_message/1)
  end

  def normalize(message), do: normalize([message])

  def convert_to_messages(messages), do: normalize(messages)

  def convert_to_openai_messages(messages, opts \\ []),
    do: OpenAI.convert(messages, opts, &normalize/1)

  def message_chunk_to_message(chunk), do: MessageChunk.to_message(chunk)

  def message_to_dict(message) do
    with {:ok, [message]} <- normalize(message) do
      {:ok, Serialization.encode(message)}
    end
  end

  def messages_to_dict(messages) do
    with {:ok, messages} <- normalize(messages) do
      {:ok, Enum.map(messages, &Serialization.encode/1)}
    end
  end

  def messages_from_dict(values) when is_list(values) do
    Result.traverse(values, &Serialization.decode/1)
  end

  def messages_from_dict(value), do: messages_from_dict([value])

  @doc """
  Filters messages by names, roles, IDs, and tool-call IDs.
  """
  @spec filter([term()], keyword()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def filter(messages, opts \\ []) do
    with {:ok, messages} <- normalize(messages) do
      {:ok, Enum.flat_map(messages, &filter_one(&1, opts))}
    end
  end

  @doc """
  Merges consecutive non-tool messages of the same role.
  """
  @spec merge_runs([term()], keyword()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def merge_runs(messages, opts \\ []) do
    separator = Keyword.get(opts, :chunk_separator, "\n")

    with {:ok, messages} <- normalize(messages) do
      {:ok,
       Enum.reduce(messages, [], fn message, acc ->
         case acc do
           [%Message{role: role} = previous | rest]
           when role == message.role and role != :tool ->
             [merge_two(previous, message, separator) | rest]

           _other ->
             [message | acc]
         end
       end)
       |> Enum.reverse()}
    end
  end

  @doc """
  Trims messages using simple first/last token strategies.
  """
  @spec trim([term()], keyword()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def trim(messages, opts) do
    with {:ok, messages} <- normalize(messages) do
      Trim.trim(messages, opts)
    end
  end

  @doc """
  Counts tokens approximately.
  """
  def count_tokens_approximately(messages, opts \\ []) do
    with {:ok, messages} <- normalize(messages) do
      {:ok, TokenCounter.count(messages, opts)}
    end
  end

  @doc """
  Adds usage metadata maps, including nested detail maps.
  """
  @spec add_usage(map() | nil, map() | nil) :: map()
  def add_usage(left, right), do: Usage.add(left, right)

  @doc """
  Subtracts usage metadata maps and clamps numeric values at zero.
  """
  @spec subtract_usage(map() | nil, map() | nil) :: map()
  def subtract_usage(left, right), do: Usage.subtract(left, right)

  @doc """
  Pretty-prints messages for debugging and tests.
  """
  def pretty_print(messages) do
    with {:ok, messages} <- normalize(messages) do
      {:ok, Enum.map_join(messages, "\n", &"#{&1.role}: #{Message.text(&1)}")}
    end
  end

  def get_buffer_string(messages, opts \\ []) do
    with {:ok, messages} <- normalize(messages) do
      Buffer.render(messages, opts)
    end
  end

  defp filter_one(%Message{} = message, opts) do
    cond do
      excluded_name?(message, opts) or excluded_role?(message, opts) or
          excluded_id?(message, opts) ->
        []

      Keyword.get(opts, :exclude_tool_calls) == true and
          (message.role == :tool or message.tool_calls != []) ->
        []

      ids = Keyword.get(opts, :exclude_tool_calls) ->
        filter_tool_call_ids(message, List.wrap(ids))

      included?(message, opts) ->
        [message]

      true ->
        []
    end
  end

  defp included?(message, opts) do
    no_includes? =
      Keyword.get(opts, :include_names) == nil and Keyword.get(opts, :include_roles) == nil and
        Keyword.get(opts, :include_types) == nil and Keyword.get(opts, :include_ids) == nil

    no_includes? or included_name?(message, opts) or included_role?(message, opts) or
      included_id?(message, opts)
  end

  defp included_name?(message, opts), do: in_opt?(message.name, opts, :include_names)
  defp excluded_name?(message, opts), do: in_opt?(message.name, opts, :exclude_names)

  defp included_role?(message, opts),
    do:
      in_role_opt?(role_name(message.role), opts, :include_roles) or
        in_role_opt?(role_name(message.role), opts, :include_types)

  defp excluded_role?(message, opts),
    do:
      in_role_opt?(role_name(message.role), opts, :exclude_roles) or
        in_role_opt?(role_name(message.role), opts, :exclude_types)

  defp included_id?(message, opts), do: in_opt?(message.id, opts, :include_ids)
  defp excluded_id?(message, opts), do: in_opt?(message.id, opts, :exclude_ids)

  defp in_opt?(nil, _opts, _key), do: false

  defp in_opt?(value, opts, key),
    do: to_string(value) in Enum.map(List.wrap(Keyword.get(opts, key)), &to_string/1)

  defp in_role_opt?(value, opts, key),
    do:
      normalize_role_alias(value) in Enum.map(
        List.wrap(Keyword.get(opts, key)),
        &normalize_role_alias/1
      )

  defp filter_tool_call_ids(%Message{role: :tool, tool_call_id: id} = message, excluded) do
    if id in excluded, do: [], else: [message]
  end

  defp filter_tool_call_ids(%Message{role: :assistant, tool_calls: calls} = message, excluded)
       when calls != [] do
    calls = Enum.reject(calls, &(tool_call_id(&1) in excluded))
    content = reject_tool_use_blocks(message.content, excluded)
    if calls == [], do: [], else: [%{message | tool_calls: calls, content: content}]
  end

  defp filter_tool_call_ids(message, _excluded), do: [message]

  defp tool_call_id(call) when is_map(call), do: Map.get(call, :id)

  defp reject_tool_use_blocks(content, excluded) when is_list(content) do
    Enum.reject(content, fn
      block when is_map(block) ->
        Map.get(block, :type) == :tool_use and tool_call_id(block) in excluded

      _block ->
        false
    end)
  end

  defp reject_tool_use_blocks(content, _excluded), do: content

  defp role_name(:user), do: "user"
  defp role_name(:assistant), do: "assistant"
  defp role_name(:system), do: "system"
  defp role_name(:tool), do: "tool"

  defp normalize_role_alias("human"), do: "user"
  defp normalize_role_alias(:human), do: "user"
  defp normalize_role_alias("ai"), do: "assistant"
  defp normalize_role_alias(:ai), do: "assistant"
  defp normalize_role_alias(value), do: to_string(value)

  defp merge_two(left, right, separator) do
    content = merge_content(left.content, right.content, separator)

    %{
      left
      | content: content,
        tool_calls: left.tool_calls ++ right.tool_calls,
        metadata: Map.merge(left.metadata, right.metadata),
        response_metadata: left.response_metadata,
        usage_metadata: merge_usage_metadata(left.usage_metadata, right.usage_metadata)
    }
  end

  defp merge_content(left, right, separator) when is_binary(left) and is_binary(right) do
    cond do
      left == "" -> right
      right == "" -> left
      true -> left <> separator <> right
    end
  end

  defp merge_content(left, right, _separator), do: List.wrap(left) ++ List.wrap(right)

  defp merge_usage_metadata(nil, nil), do: nil
  defp merge_usage_metadata(nil, right), do: right
  defp merge_usage_metadata(left, nil), do: left

  defp merge_usage_metadata(left, right) when is_map(left) and is_map(right),
    do: add_usage(left, right)
end
