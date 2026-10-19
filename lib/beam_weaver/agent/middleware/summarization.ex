defmodule BeamWeaver.Agent.Middleware.Summarization do
  @moduledoc """
  Replaces older messages with a summary once a thread gets long.

  Before each model call it checks `:trigger`; when it is reached, `:model`
  summarizes all but the newest messages and the thread is saved as one user
  message with the summary followed by the messages it kept. A tool call is
  never separated from its result. `summarize/2` does the same for a history
  outside an agent run.

  A summary call that fails is tried up to 3 times, a second or more apart,
  unless its error says retrying can't help. One that is over the model's
  context window is tried once more with the middle of the old messages cut
  out. When it still fails, the run returns its error and the thread stays
  as it was.

  A model call that fails because the request is over the model's context
  window summarizes the thread the same way, whether `:trigger` was reached
  or not, and is sent once more. The summary is saved with the reply when
  that call succeeds; when it overflows too, the run returns its error. An
  agent with `BeamWeaver.Agent.Middleware.OverflowRecovery` as well gives it
  this middleware: it clips the trailing tool results first and summarizes
  only when the call still overflows, and this middleware leaves overflows
  to it.

  Options:

    * `:model` - the model that writes summaries, a model value or a
      `"provider:model"` string. Required without `:summarizer`.
    * `:summarizer` - a function that writes the summary instead of `:model`:
      it takes the messages to summarize and returns the summary text, or
      `{:ok, text}` or `{:error, error}`.
    * `:trigger` - `{:messages, n}` (the default, 20), `{:tokens, n}`, or
      `{:fraction, f}` of `:max_input_tokens`; a list fires on any of them and
      `{:all, triggers}` on all. `nil` turns summarization off.
    * `:keep` - how much to keep word for word: `{:messages, n}` (the default,
      8), `{:tokens, n}` or `{:fraction, f}` of `:max_input_tokens`.
    * `:max_input_tokens` - the context window of the agent's model, which
      fractions are taken of. Required with a fraction; `compact_conversation`
      sets it from the agent's model.
    * `:summary_prompt` - the instruction for the summary; `{messages}` is
      replaced with the old messages.
    * `:summary_prefix` - the text before the summary in the saved message.
    * `:token_counter` - `:approximate`, a model that counts tokens, or a
      function of a message list.
    * `:trim_tokens_to_summarize` - how many tokens of old messages the summary
      model reads at most (4,000 by default; `nil` for all).
    * `:on_overflow` - `false` leaves a call over the model's context window
      to the caller instead of summarizing it (`true` by default).
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.Middleware.OverflowRecovery
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.Nodes.Model.Response
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Utils
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.RetryPolicy

  @summary_retry RetryPolicy.new!(max_attempts: 3, initial_delay: 1_000, max_delay: 10_000, jitter: true)

  defstruct model: nil,
            summarizer: nil,
            summary_prefix: "Conversation summary:",
            trigger: {:messages, 20},
            keep: {:messages, 8},
            max_input_tokens: nil,
            token_counter: :approximate,
            summary_prompt: "Summarize this conversation:\n\n{messages}",
            trim_tokens_to_summarize: 4_000,
            on_overflow: true

  def new(opts \\ []) do
    %__MODULE__{
      model: opts |> Keyword.get(:model) |> Helpers.chat_model!(),
      summarizer: Keyword.get(opts, :summarizer),
      summary_prefix: Keyword.get(opts, :summary_prefix, "Conversation summary:"),
      trigger: Keyword.get(opts, :trigger, {:messages, 20}),
      keep: Keyword.get(opts, :keep, {:messages, 8}),
      max_input_tokens: Keyword.get(opts, :max_input_tokens),
      token_counter: Keyword.get(opts, :token_counter, :approximate),
      summary_prompt: Keyword.get(opts, :summary_prompt, "Summarize this conversation:\n\n{messages}"),
      trim_tokens_to_summarize: Keyword.get(opts, :trim_tokens_to_summarize, 4_000),
      on_overflow: Keyword.get(opts, :on_overflow, true)
    }
    |> validate!()
  end

  @impl true
  def name(_middleware), do: :summarization

  @impl true
  def before_model(%__MODULE__{} = middleware, state, _runtime) do
    case summarize(middleware, State.messages(state)) do
      {:ok, %{summary: summary, kept: kept}} -> %{messages: Overwrite.new([summary | kept])}
      :unchanged -> %{}
      error -> error
    end
  end

  @doc ~S"""
  Summarizes `messages` as the middleware does before a model call, for a
  history outside an agent run.

  `:trigger` and `:keep` apply as in an agent. Returns `{:ok, %{summary:
  summary, kept: kept}}` when it summarized: `summary` is the user message
  that takes the place of the older messages, and `kept` holds the recent
  messages that follow it, without their reasoning blocks. Returns
  `:unchanged` when the trigger isn't reached or there is nothing to
  summarize, and `{:error, error}` when the summary fails.

      alias BeamWeaver.Agent.Middleware.Summarization
      alias BeamWeaver.Core.Message

      summarization =
        Summarization.new(
          summarizer: fn old -> "The customer asked #{length(old)} questions." end,
          trigger: {:messages, 4},
          keep: {:messages, 1}
        )

      history = for n <- 1..4, do: Message.user("Question #{n}")
      {:ok, %{summary: summary, kept: kept}} = Summarization.summarize(summarization, history)
      Message.text(summary)
      #=> "Conversation summary:\nThe customer asked 3 questions."
      Enum.map(kept, &Message.text/1)
      #=> ["Question 4"]
  """
  @spec summarize(%__MODULE__{}, [Message.t()]) ::
          {:ok, %{summary: Message.t(), kept: [Message.t()]}} | :unchanged | {:error, Error.t()}
  def summarize(%__MODULE__{} = middleware, messages) do
    with {:ok, messages} <- Utils.normalize(messages),
         {:ok, token_count} <- trigger_token_count(middleware, messages) do
      maybe_summarize(middleware, messages, token_count)
    end
  end

  @impl true
  def wrap_model_call(%__MODULE__{trigger: nil}, %ModelRequest{} = request, handler), do: handler.(request)
  def wrap_model_call(%__MODULE__{on_overflow: false}, %ModelRequest{} = request, handler), do: handler.(request)

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    case handler.(request) do
      {:error, %Error{} = error} = overflow ->
        if OverflowRecovery.context_overflow?(error),
          do: send_summarized(middleware, request, handler) || overflow,
          else: overflow

      result ->
        result
    end
  end

  defp maybe_summarize(%__MODULE__{trigger: nil}, _messages, _token_count), do: :unchanged

  defp maybe_summarize(%__MODULE__{} = middleware, messages, token_count) do
    if should_summarize?(middleware, messages, token_count),
      do: summarize_partition(retention_cutoff(middleware, messages), middleware, messages),
      else: :unchanged
  end

  defp summarize_partition(cutoff, _middleware, _messages) when cutoff <= 0, do: :unchanged

  defp summarize_partition(cutoff, middleware, messages) do
    {old, recent} = Enum.split(messages, cutoff)

    with {:ok, summary} <- summary_message(middleware, old) do
      {:ok, %{summary: summary, kept: Utils.strip_reasoning_blocks(recent)}}
    end
  end

  defp summary_message(middleware, old) do
    with {:ok, summary} <- create_summary(middleware, trim_messages_for_summary(middleware, old), :summarization),
         do: {:ok, Message.user(middleware.summary_prefix <> "\n" <> summary)}
  end

  @doc false
  # Sends `request` with the thread summarized as the trigger would summarize
  # it, whether it was reached or not, for a call over the model's context
  # window: the summary takes the place of the messages it covers, and is
  # saved, before the reply, only when the call succeeds. `nil` when there is
  # nothing to summarize.
  @spec send_summarized(struct(), ModelRequest.t(), (ModelRequest.t() -> term())) :: term() | nil
  def send_summarized(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    with {:ok, messages} <- Utils.normalize(State.messages(request.state || %{})),
         cutoff when cutoff > 0 <- retention_cutoff(middleware, messages),
         {old, recent} = Enum.split(messages, cutoff),
         {:ok, summary} <- summary_message(middleware, old) do
      request
      |> ModelRequest.override(messages: [summary | Utils.strip_reasoning_blocks(unsummarized(request.messages, old))])
      |> handler.()
      |> with_summary([summary | Utils.strip_reasoning_blocks(recent)])
    else
      {:error, %Error{}} = error -> error
      _nothing_to_summarize -> nil
    end
  end

  # The request's messages without its copies of the summarized ones, which
  # middleware may have changed for the call, but not their ids.
  defp unsummarized(request_messages, old) do
    ids = for %Message{id: id} <- old, not is_nil(id), into: MapSet.new(), do: id
    Enum.reject(request_messages, &(MapSet.member?(ids, &1.id) or &1 in old))
  end

  # A call that succeeds saves the summary in place of the thread, with the
  # reply, and the other messages saved with it, on top.
  defp with_summary(result, thread) do
    case Response.normalize_model_result(result) do
      {:ok, %ModelResponse{} = response} ->
        %ExtendedModelResponse{model_response: response, command: %Command{update: %{messages: Overwrite.new(thread)}}}

      _error ->
        result
    end
  end

  @doc false
  # The summary of `messages`, written the way automatic summarization writes
  # its own, retries included, for the `compact_conversation` tool; `:source`
  # tags the summary call's trace.
  @spec summary(struct(), [Message.t()], keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def summary(%__MODULE__{} = middleware, messages, opts \\ []),
    do: create_summary(middleware, messages, Keyword.get(opts, :source, :summarization))

  defp create_summary(%__MODULE__{summarizer: summarizer}, messages, _source) when is_function(summarizer, 1) do
    case summarizer.(messages) do
      {:error, %Error{}} = error ->
        error

      {:ok, summary} when is_binary(summary) ->
        {:ok, String.trim(summary)}

      summary when is_binary(summary) ->
        {:ok, String.trim(summary)}

      other ->
        {:error, Error.new(:invalid_summary, "summarizer must return the summary text", %{value: inspect(other)})}
    end
  end

  defp create_summary(%__MODULE__{} = middleware, messages, source) do
    history = history_text(messages)

    case summarize_history(middleware, history, source) do
      {:error, %Error{type: :context_overflow}} = error ->
        case cut_middle(middleware, history) do
          nil -> error
          shorter -> summarize_history(middleware, shorter, source)
        end

      result ->
        result
    end
  end

  defp summarize_history(middleware, history, source) do
    prompt = Message.user(String.replace(middleware.summary_prompt, "{messages}", history))

    case RetryPolicy.run(@summary_retry, fn ->
           ChatModel.invoke(middleware.model, [prompt], trace_metadata: %{source: source})
         end) do
      {:ok, %Message{} = summary} -> {:ok, String.trim(Message.text(summary))}
      error -> error
    end
  end

  @doc false
  # The messages as the summary model reads them, which `compact_conversation`
  # also saves to a file.
  @spec history_text([Message.t()]) :: String.t()
  def history_text(messages) do
    case Utils.buffer_string(messages) do
      {:ok, text} -> text
      _error -> inspect(messages)
    end
  end

  # The start of the history, where the task is usually stated, and its most
  # recent part, within half of its tokens and 40% of the summary model's
  # input limit when its profile has one; `nil` when nothing would be left.
  defp cut_middle(middleware, history) do
    with {:ok, tokens} when tokens > 0 <- count_messages(middleware, [Message.user(history)]) do
      budget =
        case middleware.model do
          %{profile: %{max_input_tokens: limit}} when is_integer(limit) -> min(div(tokens, 2), div(limit * 2, 5))
          _model -> div(tokens, 2)
        end

      keep = div(String.length(history) * budget, tokens)

      if keep > 0 do
        head = div(keep, 4)
        tail = keep - head

        String.slice(history, 0, head) <>
          "\n\n[... middle of conversation omitted ...]\n\n" <> String.slice(history, -tail, tail)
      end
    else
      _other -> nil
    end
  end

  defp should_summarize?(%__MODULE__{} = middleware, messages, token_count) do
    middleware.trigger
    |> List.wrap()
    |> Enum.any?(&triggered?(&1, middleware, messages, token_count))
  end

  defp triggered?({:all, triggers}, middleware, messages, token_count),
    do: Enum.all?(triggers, &triggered?(&1, middleware, messages, token_count))

  defp triggered?({:any, triggers}, middleware, messages, token_count),
    do: Enum.any?(triggers, &triggered?(&1, middleware, messages, token_count))

  defp triggered?({:messages, count}, _middleware, messages, _token_count),
    do: length(messages) >= count

  defp triggered?({:tokens, tokens}, _middleware, _messages, token_count),
    do: token_count >= tokens

  defp triggered?({:fraction, fraction}, middleware, _messages, token_count),
    do: token_count >= fraction_tokens(middleware, fraction)

  defp retention_cutoff(%__MODULE__{keep: nil}, messages), do: find_safe_cutoff(messages, 0)

  defp retention_cutoff(%__MODULE__{keep: {:messages, count}}, messages),
    do: find_safe_cutoff(messages, count)

  defp retention_cutoff(%__MODULE__{keep: {:tokens, tokens}} = middleware, messages),
    do: token_cutoff(middleware, messages, tokens)

  defp retention_cutoff(%__MODULE__{keep: {:fraction, fraction}} = middleware, messages),
    do: token_cutoff(middleware, messages, fraction_tokens(middleware, fraction))

  defp fraction_tokens(%__MODULE__{max_input_tokens: limit}, fraction), do: max(trunc(limit * fraction), 1)

  defp find_safe_cutoff(messages, messages_to_keep),
    do: Helpers.safe_cut_index(messages, max(length(messages) - messages_to_keep, 0))

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

    Helpers.safe_cut_index(messages, cutoff)
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
        total_tokens = metadata_value(usage || %{}, :total_tokens)
        response_metadata = response_metadata || %{}

        message_provider =
          metadata_value(response_metadata, :model_provider) || metadata_value(response_metadata, :provider)

        if is_integer(total_tokens) and provider_matches?(message_provider, provider), do: total_tokens

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

  defp metadata_value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp validate!(%__MODULE__{} = middleware) do
    cond do
      not (is_nil(middleware.summarizer) or is_function(middleware.summarizer, 1)) ->
        raise ArgumentError, "summarizer must be a function of the messages, got #{inspect(middleware.summarizer)}"

      is_nil(middleware.model) and is_nil(middleware.summarizer) ->
        raise ArgumentError, "summarization needs :model or :summarizer to write summaries"

      true ->
        :ok
    end

    validate_context_size!(middleware.trigger, :trigger, true)
    validate_context_size!(middleware.keep, :keep, false)

    if fractional?(middleware.trigger) or fractional?(middleware.keep) do
      unless is_integer(middleware.max_input_tokens) and middleware.max_input_tokens > 0 do
        raise ArgumentError,
              "fractional summarization limits need :max_input_tokens, the context window of the agent's model"
      end
    end

    middleware
  end

  defp validate_context_size!(nil, _field, _allow_list?), do: :ok

  defp validate_context_size!(values, field, true) when is_list(values) do
    Enum.each(values, &validate_context_size!(&1, field, false))
  end

  # Only a trigger combines conditions; `:keep` is a single size.
  defp validate_context_size!({kind, values}, :trigger, _allow_list?)
       when kind in [:all, :any] and is_list(values) do
    Enum.each(values, &validate_context_size!(&1, :trigger, false))
  end

  defp validate_context_size!({kind, value}, field, _allow_list?)
       when kind in [:messages, :tokens] do
    unless is_integer(value) and value > 0 do
      raise ArgumentError, "#{field} thresholds must be greater than 0"
    end
  end

  defp validate_context_size!({kind, value}, field, _allow_list?)
       when kind == :fraction do
    unless is_number(value) and value > 0 and value <= 1 do
      raise ArgumentError, "fractional #{field} values must be between 0 and 1"
    end
  end

  defp validate_context_size!(other, field, _allow_list?) do
    raise ArgumentError, "unsupported #{field} context size: #{inspect(other)}"
  end

  defp fractional?(values) when is_list(values), do: Enum.any?(values, &fractional?/1)
  defp fractional?({kind, values}) when kind in [:all, :any], do: fractional?(values)
  defp fractional?({kind, _value}), do: kind == :fraction
  defp fractional?(_other), do: false
end
