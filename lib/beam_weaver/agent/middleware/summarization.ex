defmodule BeamWeaver.Agent.Middleware.Summarization do
  @moduledoc """
  Summarizes long message histories with an explicit model dependency.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Utils
  alias BeamWeaver.Graph.Overwrite

  defstruct model: nil,
            summary_prefix: "Conversation summary:",
            trigger: {:messages, 20},
            keep: {:messages, 8},
            token_counter: :approximate,
            summary_prompt: "Summarize this conversation:\n\n{messages}",
            trim_tokens_to_summarize: 4_000

  def new(opts \\ []) do
    %__MODULE__{
      model: Keyword.fetch!(opts, :model),
      summary_prefix: Keyword.get(opts, :summary_prefix, "Conversation summary:"),
      trigger: Keyword.get(opts, :trigger, {:messages, 20}),
      keep: Keyword.get(opts, :keep, {:messages, 8}),
      token_counter: Keyword.get(opts, :token_counter, :approximate),
      summary_prompt: Keyword.get(opts, :summary_prompt, "Summarize this conversation:\n\n{messages}"),
      trim_tokens_to_summarize: Keyword.get(opts, :trim_tokens_to_summarize, 4_000)
    }
    |> validate!()
  end

  @impl true
  def name(_middleware), do: :summarization

  def before_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = State.messages(state)

    with {:ok, messages} <- Utils.normalize(messages),
         {:ok, token_count} <- trigger_token_count(middleware, messages) do
      maybe_summarize(middleware, messages, token_count)
    end
  end

  defp maybe_summarize(%__MODULE__{trigger: nil}, _messages, _token_count), do: %{}

  defp maybe_summarize(%__MODULE__{} = middleware, messages, token_count) do
    if should_summarize?(middleware, messages, token_count) do
      cutoff = retention_cutoff(middleware, messages)

      if cutoff <= 0 do
        %{}
      else
        summarize_partition(cutoff, middleware, messages)
      end
    else
      %{}
    end
  end

  defp summarize_partition(cutoff, _middleware, _messages) when cutoff <= 0, do: %{}

  defp summarize_partition(cutoff, middleware, messages) do
    {old, recent} = Enum.split(messages, cutoff)

    with {:ok, summary_prompt} <- summary_prompt(middleware, old) do
      case ChatModel.invoke(middleware.model, [summary_prompt], metadata: %{lc_source: "summarization"}) do
        {:ok, %Message{} = summary} ->
          %{
            messages:
              Overwrite.new([
                Message.system(middleware.summary_prefix <> "\n" <> Message.text(summary))
                | recent
              ])
          }

        error ->
          error
      end
    end
  end

  defp summary_prompt(middleware, messages) do
    messages = trim_messages_for_summary(middleware, messages)

    case Utils.get_buffer_string(messages) do
      {:ok, text} ->
        {:ok, Message.user(String.replace(middleware.summary_prompt, "{messages}", text))}

      _error ->
        {:ok, Message.user(String.replace(middleware.summary_prompt, "{messages}", inspect(messages)))}
    end
  end

  defp should_summarize?(%__MODULE__{} = middleware, messages, token_count) do
    middleware.trigger
    |> List.wrap()
    |> Enum.any?(&triggered?(&1, middleware, messages, token_count))
  end

  defp triggered?({:messages, count}, _middleware, messages, _token_count),
    do: length(messages) >= count

  defp triggered?({"messages", count}, middleware, messages, token_count),
    do: triggered?({:messages, count}, middleware, messages, token_count)

  defp triggered?({:tokens, tokens}, _middleware, _messages, token_count),
    do: token_count >= tokens

  defp triggered?({"tokens", tokens}, middleware, messages, token_count),
    do: triggered?({:tokens, tokens}, middleware, messages, token_count)

  defp triggered?({:fraction, fraction}, middleware, _messages, token_count) do
    case profile_limit(middleware.model) do
      limit when is_integer(limit) and limit > 0 ->
        token_count >= max(trunc(limit * fraction), 1)

      _missing ->
        false
    end
  end

  defp triggered?({"fraction", fraction}, middleware, messages, token_count),
    do: triggered?({:fraction, fraction}, middleware, messages, token_count)

  defp retention_cutoff(%__MODULE__{keep: nil}, messages), do: find_safe_cutoff(messages, 0)

  defp retention_cutoff(%__MODULE__{keep: {:messages, count}}, messages),
    do: find_safe_cutoff(messages, count)

  defp retention_cutoff(%__MODULE__{keep: {"messages", count}}, messages),
    do: find_safe_cutoff(messages, count)

  defp retention_cutoff(%__MODULE__{keep: {:tokens, tokens}} = middleware, messages),
    do: token_cutoff(middleware, messages, tokens)

  defp retention_cutoff(%__MODULE__{keep: {"tokens", tokens}} = middleware, messages),
    do: token_cutoff(middleware, messages, tokens)

  defp retention_cutoff(%__MODULE__{keep: {:fraction, fraction}} = middleware, messages) do
    case profile_limit(middleware.model) do
      limit when is_integer(limit) and limit > 0 ->
        token_cutoff(middleware, messages, max(trunc(limit * fraction), 1))

      _missing ->
        find_safe_cutoff(messages, 0)
    end
  end

  defp retention_cutoff(%__MODULE__{keep: {"fraction", fraction}} = middleware, messages),
    do: retention_cutoff(%{middleware | keep: {:fraction, fraction}}, messages)

  defp find_safe_cutoff(messages, messages_to_keep) do
    messages
    |> length()
    |> Kernel.-(messages_to_keep)
    |> max(0)
    |> safe_cutoff_point(messages)
  end

  defp token_cutoff(middleware, messages, target_tokens) do
    cutoff =
      0..length(messages)
      |> Enum.find(length(messages), fn index ->
        suffix = Enum.drop(messages, index)

        case count_messages(middleware, suffix) do
          {:ok, count} -> count <= target_tokens
          {:error, _error} -> false
        end
      end)

    safe_cutoff_point(cutoff, messages)
  end

  defp safe_cutoff_point(index, messages) when index >= length(messages), do: index

  defp safe_cutoff_point(index, messages) do
    case Enum.at(messages, index) do
      %Message{role: :tool, tool_call_id: id} when is_binary(id) ->
        case matching_ai_index(messages, index, id) do
          nil -> skip_tool_messages(messages, index)
          ai_index -> ai_index
        end

      _message ->
        index
    end
  end

  defp matching_ai_index(messages, index, tool_call_id) do
    messages
    |> Enum.take(index)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: :assistant, tool_calls: calls}, ai_index} when is_list(calls) ->
        if Enum.any?(calls, &(tool_call_id(&1) == tool_call_id)), do: ai_index

      _other ->
        nil
    end)
  end

  defp skip_tool_messages(messages, index) do
    messages
    |> Enum.drop(index)
    |> Enum.take_while(&match?(%Message{role: :tool}, &1))
    |> length()
    |> Kernel.+(index)
  end

  defp trim_messages_for_summary(%__MODULE__{trim_tokens_to_summarize: nil}, messages),
    do: messages

  defp trim_messages_for_summary(%__MODULE__{} = middleware, messages) do
    case Utils.trim(messages,
           max_tokens: middleware.trim_tokens_to_summarize,
           token_counter: trim_token_counter(middleware.token_counter),
           strategy: :last
         ) do
      {:ok, trimmed} -> trimmed
      {:error, _error} -> Enum.take(messages, -15)
    end
  end

  defp count_messages(%__MODULE__{token_counter: :approximate}, messages),
    do: Utils.count_tokens_approximately(messages)

  defp count_messages(%__MODULE__{token_counter: counter}, messages)
       when is_function(counter, 1) do
    {:ok, counter.(messages)}
  rescue
    exception ->
      {:error,
       Error.new(:token_count_failed, Exception.message(exception), %{
         counter: inspect(counter)
       })}
  end

  defp count_messages(%__MODULE__{token_counter: counter}, messages),
    do: LanguageModel.count_tokens(counter, messages)

  defp trim_token_counter(counter) when is_function(counter, 1) do
    fn
      messages when is_list(messages) -> counter.(messages)
      message -> counter.([message])
    end
  end

  defp trim_token_counter(counter), do: counter

  defp trigger_token_count(%__MODULE__{token_counter: :approximate} = middleware, messages) do
    with {:ok, count} <- count_messages(middleware, messages) do
      {:ok, max(count, reported_token_count(middleware, messages) || count)}
    end
  end

  defp trigger_token_count(%__MODULE__{} = middleware, messages),
    do: count_messages(middleware, messages)

  defp reported_token_count(%__MODULE__{} = middleware, messages) do
    provider = model_provider(middleware.model)

    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant, usage_metadata: usage, response_metadata: response_metadata} ->
        case metadata_value(usage || %{}, :total_tokens) do
          total_tokens when is_integer(total_tokens) ->
            message_provider =
              metadata_value(response_metadata || %{}, :model_provider) ||
                metadata_value(response_metadata || %{}, :provider)

            if provider_matches?(message_provider, provider), do: total_tokens, else: nil

          _missing ->
            nil
        end

      _message ->
        nil
    end)
  end

  defp model_provider(%{profile: %{provider: provider}}) when not is_nil(provider), do: provider
  defp model_provider(%{provider: provider}) when not is_nil(provider), do: provider
  defp model_provider(_model), do: nil

  defp provider_matches?(nil, _model_provider), do: false
  defp provider_matches?(_message_provider, nil), do: false

  defp provider_matches?(message_provider, model_provider) do
    message_provider = normalize_provider(message_provider)
    model_provider = normalize_provider(model_provider)

    message_provider == model_provider or
      {message_provider, model_provider} in [
        {"bedrock", "amazon_bedrock"},
        {"bedrock_converse", "amazon_bedrock"},
        {"amazon_bedrock", "bedrock"},
        {"amazon_bedrock", "bedrock_converse"}
      ]
  end

  defp normalize_provider(provider), do: provider |> to_string() |> String.downcase()

  defp metadata_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp metadata_value(_map, _key), do: nil

  defp profile_limit(%{profile: %{max_input_tokens: limit}}) when is_integer(limit), do: limit
  defp profile_limit(%{profile: %{"max_input_tokens" => limit}}) when is_integer(limit), do: limit
  defp profile_limit(_model), do: nil

  defp tool_call_id(%{"id" => id}), do: id
  defp tool_call_id(%{id: id}), do: id
  defp tool_call_id(_call), do: nil

  defp validate!(%__MODULE__{} = middleware) do
    validate_context_size!(middleware.trigger, :trigger, true)
    validate_context_size!(middleware.keep, :keep, false)

    if fractional?(middleware.trigger) or fractional?(middleware.keep) do
      unless is_integer(profile_limit(middleware.model)) do
        raise ArgumentError,
              "model profile with max_input_tokens is required for fractional summarization limits"
      end
    end

    middleware
  end

  defp validate_context_size!(nil, _field, _allow_list?), do: :ok

  defp validate_context_size!(values, field, true) when is_list(values) do
    Enum.each(values, &validate_context_size!(&1, field, false))
  end

  defp validate_context_size!({kind, value}, field, _allow_list?)
       when kind in [:messages, "messages", :tokens, "tokens"] do
    unless is_integer(value) and value > 0 do
      raise ArgumentError, "#{field} thresholds must be greater than 0"
    end
  end

  defp validate_context_size!({kind, value}, field, _allow_list?)
       when kind in [:fraction, "fraction"] do
    unless is_number(value) and value > 0 and value <= 1 do
      raise ArgumentError, "fractional #{field} values must be between 0 and 1"
    end
  end

  defp validate_context_size!(other, field, _allow_list?) do
    raise ArgumentError, "unsupported #{field} context size: #{inspect(other)}"
  end

  defp fractional?(values) when is_list(values), do: Enum.any?(values, &fractional?/1)
  defp fractional?({kind, _value}), do: kind in [:fraction, "fraction"]
  defp fractional?(_other), do: false
end
