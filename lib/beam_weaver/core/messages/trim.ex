defmodule BeamWeaver.Core.Messages.Trim do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message

  def trim(messages, opts) when is_list(messages) do
    max_tokens = Keyword.fetch!(opts, :max_tokens)
    counter = Keyword.get(opts, :token_counter, :approximate)
    strategy = Keyword.get(opts, :strategy, :last)

    with :ok <- validate_trim_opts(strategy, opts),
         messages = apply_end_on(messages, Keyword.get(opts, :end_on)),
         {:ok, kept} <- keep_by_strategy(messages, max_tokens, counter, strategy, opts) do
      {:ok, kept |> apply_start_on(Keyword.get(opts, :start_on), opts) |> preserve_tool_adjacency()}
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

  defp apply_end_on(messages, nil), do: messages

  defp apply_end_on(messages, role) do
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
    {system, candidates} = split_system(messages, opts)

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
              case partial_message(message, max_tokens - count, counter, direction) do
                {:ok, nil} -> {:halt, {:ok, {acc, count}}}
                {:ok, partial} -> {:halt, {:ok, {[partial | acc], max_tokens}}}
                {:error, %Error{} = error} -> {:halt, {:error, error}}
              end

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
    {system, messages} = split_system(messages, opts)

    case Enum.find_index(messages, &role_match?(&1, role)) do
      nil -> system ++ messages
      index -> system ++ Enum.drop(messages, index)
    end
  end

  defp split_system(messages, opts) do
    if Keyword.get(opts, :include_system) && match?([%Message{role: :system} | _], messages),
      do: {[hd(messages)], tl(messages)},
      else: {[], messages}
  end

  defp role_match?(%Message{role: message_role}, roles) when is_list(roles),
    do: Enum.any?(roles, &role_match?(%Message{role: message_role, content: ""}, &1))

  defp role_match?(%Message{role: message_role}, role),
    do: Atom.to_string(message_role) == to_string(role)

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
    tool_result_ids = for %Message{role: :tool, tool_call_id: id} <- messages, into: MapSet.new(), do: id

    messages =
      Enum.map(messages, fn
        %Message{role: :assistant, tool_calls: calls} = message when calls != [] ->
          %{message | tool_calls: Enum.filter(calls, &(Map.get(&1, :id) in tool_result_ids))}

        message ->
          message
      end)

    assistant_call_ids =
      for %Message{role: :assistant, tool_calls: calls} <- messages,
          call <- calls,
          into: MapSet.new(),
          do: Map.get(call, :id)

    Enum.reject(messages, fn
      %Message{role: :tool, tool_call_id: id} -> not MapSet.member?(assistant_call_ids, id)
      _message -> false
    end)
  end

  # Keeps as many words (and, for content blocks, whole blocks) as fit in
  # `remaining`, measured with the same counter as whole messages. Returns nil
  # when not even one word fits.
  defp partial_message(%Message{content: content} = message, remaining, counter, direction)
       when is_binary(content) do
    words = words(content)
    build = &%{message | content: join_words(words, &1, direction)}

    with {:ok, fitting} <- largest_fitting(length(words), build, remaining, counter) do
      {:ok, if(fitting == 0, do: nil, else: build.(fitting))}
    end
  end

  defp partial_message(%Message{content: content} = message, remaining, counter, direction)
       when is_list(content) do
    blocks = if direction == :last, do: Enum.reverse(content), else: content

    with {:ok, kept} <- partial_blocks(blocks, [], message, remaining, counter, direction) do
      {:ok, if(kept == [], do: nil, else: with_blocks(message, kept, direction))}
    end
  end

  defp partial_message(_message, _remaining, _counter, _direction), do: {:ok, nil}

  # `kept` and `blocks` run in trimming order: from the end for `:last`.
  defp partial_blocks([], kept, _message, _remaining, _counter, _direction), do: {:ok, kept}

  defp partial_blocks([block | rest], kept, message, remaining, counter, direction) do
    with {:ok, count} <- token_count(counter, with_blocks(message, kept ++ [block], direction)) do
      cond do
        count <= remaining ->
          partial_blocks(rest, kept ++ [block], message, remaining, counter, direction)

        text_block?(block) ->
          words = block |> block_text() |> words()
          cut = &put_block_text(block, join_words(words, &1, direction))
          build = &with_blocks(message, kept ++ [cut.(&1)], direction)

          with {:ok, fitting} <- largest_fitting(length(words), build, remaining, counter) do
            {:ok, if(fitting == 0, do: kept, else: kept ++ [cut.(fitting)])}
          end

        true ->
          {:ok, kept}
      end
    end
  end

  defp with_blocks(message, kept, :first), do: %{message | content: kept}
  defp with_blocks(message, kept, :last), do: %{message | content: Enum.reverse(kept)}

  # The largest `n` in 0..total for which `build.(n)` fits in `remaining`.
  defp largest_fitting(total, build, remaining, counter), do: search(0, total, build, remaining, counter)

  defp search(low, high, _build, _remaining, _counter) when low >= high, do: {:ok, low}

  defp search(low, high, build, remaining, counter) do
    middle = div(low + high + 1, 2)

    case token_count(counter, build.(middle)) do
      {:ok, count} when count <= remaining -> search(middle, high, build, remaining, counter)
      {:ok, _count} -> search(low, middle - 1, build, remaining, counter)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp words(text), do: String.split(text, ~r/\s+/, trim: true)

  defp join_words(words, count, :first), do: words |> Enum.take(count) |> Enum.join(" ")
  defp join_words(words, count, :last), do: words |> Enum.take(-count) |> Enum.join(" ")

  defp block_text(text) when is_binary(text), do: text
  defp block_text(block), do: to_string(Map.get(block, :text))

  defp put_block_text(text, new_text) when is_binary(text), do: new_text
  defp put_block_text(block, new_text), do: Map.put(block, :text, new_text)

  defp text_block?(text) when is_binary(text), do: true

  defp text_block?(%{type: type, text: text}) when type in [:text, :plain_text] and is_binary(text),
    do: true

  defp text_block?(_block), do: false
end
