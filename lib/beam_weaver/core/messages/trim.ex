defmodule BeamWeaver.Core.Messages.Trim do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message

  def trim(messages, opts) when is_list(messages) do
    max_tokens = Keyword.fetch!(opts, :max_tokens)
    counter = Keyword.get(opts, :token_counter, :approximate)
    strategy = Keyword.get(opts, :strategy, :last)

    with :ok <- validate_trim_opts(strategy, opts) do
      messages = apply_end_on(messages, Keyword.get(opts, :end_on), strategy)

      with {:ok, kept} <- keep_by_strategy(messages, max_tokens, counter, strategy, opts) do
        kept =
          kept
          |> apply_start_on(Keyword.get(opts, :start_on), opts)
          |> preserve_tool_adjacency()

        {:ok, kept}
      end
    end
  end

  defp validate_trim_opts(:first, opts) do
    cond do
      Keyword.get(opts, :start_on) ->
        {:error, Error.new(:invalid_trim_options, "start_on requires strategy :last")}

      Keyword.get(opts, :include_system) ->
        {:error, Error.new(:invalid_trim_options, "include_system requires strategy :last")}

      true ->
        :ok
    end
  end

  defp validate_trim_opts(:last, _opts), do: :ok

  defp validate_trim_opts(strategy, _opts),
    do: {:error, Error.new(:invalid_trim_options, "unknown trim strategy", %{strategy: strategy})}

  defp apply_end_on(messages, nil, _strategy), do: messages

  defp apply_end_on(messages, role, _strategy) do
    case Enum.find_index(Enum.reverse(messages), &role_match?(&1, role)) do
      nil -> messages
      reverse_index -> Enum.take(messages, length(messages) - reverse_index)
    end
  end

  defp keep_by_strategy(messages, max_tokens, counter, :first, opts) do
    keep_until_budget(
      messages,
      max_tokens,
      counter,
      Keyword.get(opts, :allow_partial, false),
      :first
    )
  end

  defp keep_by_strategy(messages, max_tokens, counter, :last, opts) do
    system =
      if Keyword.get(opts, :include_system, false) and
           match?([%Message{role: :system} | _], messages),
         do: [hd(messages)],
         else: []

    candidates = if system == [], do: messages, else: tl(messages)

    with {:ok, kept} <-
           candidates
           |> Enum.reverse()
           |> keep_until_budget(
             max_tokens,
             counter,
             Keyword.get(opts, :allow_partial, false),
             :last
           ) do
      {:ok, system ++ Enum.reverse(kept)}
    end
  end

  defp keep_until_budget(messages, max_tokens, counter, allow_partial, direction) do
    Enum.reduce_while(messages, {:ok, {[], 0}}, fn message, {:ok, {acc, count}} ->
      case token_count(counter, message) do
        {:ok, token_count} ->
          cond do
            count + token_count <= max_tokens ->
              {:cont, {:ok, {[message | acc], count + token_count}}}

            allow_partial ->
              partial = partial_message(message, max_tokens - count, direction)
              {:halt, {:ok, {[partial | acc], max_tokens}}}

            true ->
              {:halt, {:ok, {acc, count}}}
          end

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, {kept, _count}} -> {:ok, Enum.reverse(kept)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp apply_start_on(messages, nil, _opts), do: messages

  defp apply_start_on(messages, role, opts) do
    {system, messages} =
      if Keyword.get(opts, :include_system, false) and
           match?([%Message{role: :system} | _], messages),
         do: {[hd(messages)], tl(messages)},
         else: {[], messages}

    case Enum.find_index(messages, &role_match?(&1, role)) do
      nil -> system ++ messages
      index -> system ++ Enum.drop(messages, index)
    end
  end

  defp role_match?(%Message{role: message_role}, roles) when is_list(roles),
    do: Enum.any?(roles, &role_match?(%Message{role: message_role, content: ""}, &1))

  defp role_match?(%Message{role: message_role}, role),
    do: normalize_role_alias(role_name(message_role)) == normalize_role_alias(role)

  defp token_count(counter, value) do
    case LanguageModel.count_tokens(counter, value) do
      {:ok, count} when is_integer(count) and count >= 0 ->
        {:ok, count}

      {:error, %Error{} = error} ->
        {:error, error}

      other ->
        {:error,
         Error.new(:invalid_token_counter, "token counter returned an invalid value", %{
           value: inspect(other)
         })}
    end
  end

  defp preserve_tool_adjacency(messages) do
    tool_result_ids =
      messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.map(& &1.tool_call_id)
      |> MapSet.new()

    messages
    |> Enum.map(fn
      %Message{role: :assistant, tool_calls: calls} = message when calls != [] ->
        %{message | tool_calls: Enum.filter(calls, &(tool_call_id(&1) in tool_result_ids))}

      message ->
        message
    end)
    |> then(fn messages ->
      assistant_call_ids =
        messages
        |> Enum.flat_map(fn
          %Message{role: :assistant, tool_calls: calls} -> Enum.map(calls, &tool_call_id/1)
          _message -> []
        end)
        |> MapSet.new()

      Enum.reject(messages, fn
        %Message{role: :tool, tool_call_id: id} -> not MapSet.member?(assistant_call_ids, id)
        _message -> false
      end)
    end)
  end

  defp partial_message(%Message{content: content} = message, remaining, :first)
       when is_binary(content) do
    %{message | content: content |> words() |> Enum.take(max(remaining, 0)) |> Enum.join(" ")}
  end

  defp partial_message(%Message{content: content} = message, remaining, :last)
       when is_binary(content) do
    %{message | content: content |> words() |> Enum.take(-max(remaining, 0)) |> Enum.join(" ")}
  end

  defp partial_message(%Message{content: content} = message, remaining, direction)
       when is_list(content) do
    %{message | content: partial_content(content, max(remaining, 0), direction)}
  end

  defp partial_message(message, _remaining, _direction), do: message

  defp words(text), do: String.split(text, ~r/\s+/, trim: true)

  defp partial_content(content, remaining, :first),
    do: partial_content_forward(content, remaining)

  defp partial_content(content, remaining, :last) do
    content
    |> Enum.reverse()
    |> partial_content_forward(remaining)
    |> Enum.reverse()
  end

  defp partial_content_forward(content, remaining) do
    content
    |> Enum.reduce_while({[], remaining}, fn block, {acc, remaining} ->
      count = content_block_token_count(block)

      cond do
        remaining <= 0 ->
          {:halt, {acc, remaining}}

        count <= remaining ->
          {:cont, {[block | acc], remaining - count}}

        text_block?(block) ->
          {:halt, {[truncate_text_block(block, remaining) | acc], 0}}

        true ->
          {:halt, {acc, remaining}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp content_block_token_count(text) when is_binary(text), do: length(words(text))
  defp content_block_token_count(%ContentBlock.Text{text: text}), do: length(words(text || ""))
  defp content_block_token_count(%ContentBlock.PlainText{text: text}), do: length(words(text || ""))

  defp content_block_token_count(block) when is_map(block) do
    if text_block?(block), do: length(words(Map.get(block, :text) || "")), else: 1
  end

  defp content_block_token_count(_block), do: 1

  defp truncate_text_block(text, remaining) when is_binary(text) do
    text |> words() |> Enum.take(remaining) |> Enum.join(" ")
  end

  defp truncate_text_block(%ContentBlock.Text{} = block, remaining) do
    %{block | text: block.text |> to_string() |> words() |> Enum.take(remaining) |> Enum.join(" ")}
  end

  defp truncate_text_block(%ContentBlock.PlainText{} = block, remaining) do
    %{block | text: block.text |> to_string() |> words() |> Enum.take(remaining) |> Enum.join(" ")}
  end

  defp truncate_text_block(block, remaining) when is_map(block) do
    text = block |> Map.get(:text) |> to_string()
    truncated = text |> words() |> Enum.take(remaining) |> Enum.join(" ")

    Map.put(block, :text, truncated)
  end

  defp tool_call_id(call) when is_map(call), do: Map.get(call, :id)

  defp text_block?(%ContentBlock.Text{text: text}) when is_binary(text), do: true
  defp text_block?(%ContentBlock.PlainText{text: text}) when is_binary(text), do: true

  defp text_block?(%{type: type, text: text}) when type in [:text, :plain_text] and is_binary(text),
    do: true

  defp text_block?(_block), do: false

  defp normalize_role_alias("human"), do: "user"
  defp normalize_role_alias(:human), do: "user"
  defp normalize_role_alias("ai"), do: "assistant"
  defp normalize_role_alias(:ai), do: "assistant"
  defp normalize_role_alias(value), do: to_string(value)

  defp role_name(:user), do: "user"
  defp role_name(:assistant), do: "assistant"
  defp role_name(:system), do: "system"
  defp role_name(:tool), do: "tool"
end
