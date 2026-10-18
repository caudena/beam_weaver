defmodule BeamWeaver.Agent.Middleware.OverflowRecovery do
  @moduledoc """
  Recovers from context overflow errors by clipping large tool results.

  When a model call fails because the request is too long for the model, the
  middleware clips the trailing batch of tool results and retries once. A
  generic result is saved to a file under `/large_tool_results/` and replaced
  with a preview of its first and last lines; a `read_file` result is cut to
  its first 4,000 characters and points back to the file it came from. When
  the retry succeeds, the clipped results replace the full ones in the saved
  thread, and with `BeamWeaver.Filesystem.State` the saved files are added to
  the thread's files, so later calls don't send the full results again.

  With `:summarization`, a call that still overflows once its results are
  clipped, or that has nothing to clip, is sent once more with the thread
  summarized, and keeps the results clipped. An agent with automatic
  summarization (`BeamWeaver.Agent.Middleware.Summarization`) as well gives
  it here, so the two can be listed in any order. A call that overflows is
  sent at most twice more.

  Options:

    * `:keep` - how large the trailing batch may be before it is clipped:
      `{:tokens, n}` (the default is `{:tokens, 5_000}`) or `{:fraction, f}` of
      `:max_input_tokens` (5,000 tokens when that is unknown).
    * `:max_input_tokens` - the model's context window; `overflow_recovery`
      sets it from the agent's model.
    * `:backend` - the filesystem the results are saved to.
    * `:token_counter` - `:approximate` or a function of a message list.
    * `:large_tool_results_prefix` - the directory for the saved results.
    * `:summarization` - a `BeamWeaver.Agent.Middleware.Summarization` that
      summarizes the thread when clipping isn't enough.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.Middleware.Offload
  alias BeamWeaver.Agent.Middleware.Summarization
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.State, as: AgentState
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Utils, as: MessageUtils
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.MapAccess
  alias BeamWeaver.MapShape
  alias BeamWeaver.Options
  alias BeamWeaver.Provider.ResponseDecoder

  @chars_per_token 4
  @default_keep {:tokens, 5_000}
  @default_threshold_tokens 5_000

  @read_file_truncation_notice """

  [Output was truncated due to context window size limits. The full content is at %{file_path}. Use read_file with offset and limit parameters to retrieve specific portions. For example, to read the first 100 lines, call read_file with file_path='%{file_path}', offset=0, limit=100.]
  """

  defstruct messages: [],
            replacements: [],
            files_update: nil,
            clipped?: false,
            backend: nil,
            keep: @default_keep,
            max_input_tokens: nil,
            token_counter: :approximate,
            large_tool_results_prefix: nil,
            state_key: :files,
            retry?: true,
            summarization: nil

  @type t :: %__MODULE__{
          messages: [Message.t()],
          replacements: [Message.t()],
          files_update: map() | nil,
          clipped?: boolean(),
          backend: Filesystem.t() | nil,
          keep: term(),
          max_input_tokens: integer() | nil,
          token_counter: term(),
          large_tool_results_prefix: String.t() | nil,
          state_key: atom(),
          retry?: boolean(),
          summarization: struct() | nil
        }

  def new(opts \\ []) do
    keep = Keyword.get(opts, :keep, @default_keep)
    max_input_tokens = Keyword.get(opts, :max_input_tokens)
    # Raises for a setting other than `{:tokens, n}` or `{:fraction, f}`.
    derive_threshold_tokens(keep, max_input_tokens)

    %__MODULE__{
      backend: Keyword.get(opts, :backend, State.new()),
      keep: keep,
      max_input_tokens: max_input_tokens,
      token_counter: Keyword.get(opts, :token_counter, :approximate),
      large_tool_results_prefix: Keyword.get(opts, :large_tool_results_prefix),
      state_key: Keyword.get(opts, :state_key, :files),
      retry?: Keyword.get(opts, :retry, true),
      summarization: Keyword.get(opts, :summarization)
    }
  end

  @impl true
  def name(_middleware), do: :deepagents_overflow_clip

  @impl true
  def wrap_model_call(%__MODULE__{retry?: false}, %ModelRequest{} = request, handler),
    do: handler.(request)

  # A call that overflows is sent once more with its trailing tool results
  # clipped, and then, with `:summarization`, once more with the thread
  # summarized.
  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    with {:overflow, overflow} <- sent(handler.(request)),
         {:overflow, overflow, request, send} <- send_clipped(middleware, request, handler, overflow) do
      send_summarized(middleware, request, send) || overflow
    else
      {:sent, result} -> result
    end
  end

  @doc """
  Derives the tail clipping threshold, in tokens, from a `:keep` setting.

  `{:tokens, n}` uses `n`, and `{:fraction, f}` uses `f` times
  `max_input_tokens`, or 5,000 tokens when that is unknown. Any other setting
  raises `ArgumentError`.
  """
  def derive_threshold_tokens({:tokens, value}, _max_input_tokens)
      when is_integer(value) and value > 0,
      do: value

  def derive_threshold_tokens({:fraction, value}, max_input_tokens)
      when is_number(value) and value > 0 and value <= 1 do
    case max_input_tokens do
      limit when is_integer(limit) and limit > 0 -> trunc(limit * value)
      _missing -> @default_threshold_tokens
    end
  end

  def derive_threshold_tokens({kind, _value}, _max_input_tokens) when is_binary(kind) do
    {:error, message} = Options.atom_enum_error("keep kind", kind, [:tokens, :fraction])
    raise ArgumentError, message
  end

  def derive_threshold_tokens(keep, _max_input_tokens) do
    raise ArgumentError,
          "overflow_recovery keep must be {:tokens, n} or {:fraction, f} with 0 < f <= 1, got: #{inspect(keep)}"
  end

  @doc """
  Clips an oversized trailing tool-message batch.

  Options:

  - `:keep` - `{:tokens, n}` or `{:fraction, f}`, default `{:tokens, 5_000}`.
  - `:max_input_tokens` - model input token limit for fractional keep settings.
  - `:token_counter` - `:approximate` or a one-arity function.
  - `:large_tool_results_prefix` - virtual output prefix.
  - `:state`, `:runtime`, `:store`, `:state_key` - backend write context.
  """
  @spec clip_tail([Message.t()], Filesystem.t(), keyword()) :: t()
  def clip_tail(messages, backend \\ State.new(), opts \\ []) when is_list(messages) do
    case tail_tool_batch(messages) do
      nil ->
        %__MODULE__{messages: messages}

      {start, tail} ->
        maybe_clip_tail(messages, backend, opts, start, tail)
    end
  end

  @doc false
  # Whether a model call failed because the request is over the model's
  # context window. A model that doesn't decode its errors, or a proxy that
  # passes an overflow on as a bad request, leaves only the message to tell
  # an overflow apart.
  @spec context_overflow?(Error.t()) :: boolean()
  def context_overflow?(%Error{type: :context_overflow}), do: true
  def context_overflow?(%Error{message: message}), do: ResponseDecoder.context_overflow_message?(message)

  # An overflow goes on to the next step of the recovery; any other result is
  # the call's.
  defp sent({:error, %Error{} = error} = result),
    do: if(context_overflow?(error), do: {:overflow, result}, else: {:sent, result})

  defp sent(result), do: {:sent, result}

  # Sends `request` with its trailing tool results clipped. When that
  # overflows too, the clipped request goes on to be summarized, sent through
  # a handler that saves the clip with the reply; when there is nothing to
  # clip, the request goes on as it is.
  defp send_clipped(%__MODULE__{} = middleware, %ModelRequest{} = request, handler, overflow) do
    result =
      clip_tail(request.messages, middleware.backend || State.new(),
        keep: middleware.keep,
        max_input_tokens: middleware.max_input_tokens,
        token_counter: middleware.token_counter,
        large_tool_results_prefix: middleware.large_tool_results_prefix,
        state: request.state || %{},
        runtime: request.runtime,
        state_key: middleware.state_key
      )

    if result.clipped? do
      clipped =
        ModelRequest.override(request,
          messages: result.messages,
          state: clipped_state(middleware, request.state || %{}, result)
        )

      send = &(&1 |> handler.() |> save_clip(middleware, request, result))

      with {:overflow, overflow} <- sent(send.(clipped)), do: {:overflow, overflow, clipped, send}
    else
      {:overflow, overflow, request, handler}
    end
  end

  defp send_summarized(%__MODULE__{summarization: nil}, _request, _send), do: nil

  defp send_summarized(%__MODULE__{summarization: summarization}, request, send),
    do: Summarization.send_summarized(summarization, request, send)

  # The clipped call sees the thread as it is saved when the call succeeds,
  # with the clipped results and their files, so that a summary of it keeps
  # them clipped.
  defp clipped_state(%__MODULE__{} = middleware, state, result) do
    clipped = Map.new(result.replacements, &{&1.id, &1})

    state
    |> Map.put(:messages, Enum.map(AgentState.messages(state), &Map.get(clipped, &1.id, &1)))
    |> Offload.put_files_update(middleware.state_key, result.files_update)
  end

  # A successful retry also saves the clipped results in place of the full
  # ones, and the saved files with a state filesystem, so the next call on the
  # thread doesn't overflow again.
  defp save_clip({:ok, %ModelResponse{} = response}, %__MODULE__{} = middleware, request, result) do
    saved_ids = MapSet.new(for %Message{id: id} <- AgentState.messages(request.state || %{}), do: id)

    case Enum.filter(result.replacements, &MapSet.member?(saved_ids, &1.id)) do
      [] when is_nil(result.files_update) ->
        {:ok, response}

      replacements ->
        update = MapShape.put_present(%{messages: replacements}, middleware.state_key, result.files_update)
        %ExtendedModelResponse{model_response: response, command: %Command{update: update}}
    end
  end

  defp save_clip(other, _middleware, _request, _result), do: other

  defp maybe_clip_tail(messages, backend, opts, start, tail) do
    threshold =
      derive_threshold_tokens(
        Keyword.get(opts, :keep, @default_keep),
        Keyword.get(opts, :max_input_tokens)
      )

    if count_tokens(tail, Keyword.get(opts, :token_counter, :approximate)) < threshold do
      %__MODULE__{messages: messages}
    else
      do_clip_tail(messages, backend, opts, start, tail)
    end
  end

  defp do_clip_tail(messages, backend, opts, start, tail) do
    tool_call_index = build_tool_call_index(messages)

    {new_tail, replacements, files_update} =
      Enum.reduce(tail, {[], [], nil}, fn message, {new_tail, replacements, files_acc} ->
        case clip_one(message, tool_call_index, backend, opts, files_acc) do
          {nil, files_acc} ->
            {new_tail ++ [message], replacements, files_acc}

          {%Message{} = clipped, files_acc} ->
            clipped = ensure_id(clipped)
            {new_tail ++ [clipped], replacements ++ [clipped], files_acc}
        end
      end)

    if replacements == [] do
      %__MODULE__{messages: messages}
    else
      %__MODULE__{
        messages: Enum.take(messages, start) ++ new_tail,
        replacements: replacements,
        files_update: files_update,
        clipped?: true
      }
    end
  end

  defp tail_tool_batch([]), do: nil

  defp tail_tool_batch(messages) do
    if match?(%Message{role: :tool}, List.last(messages)) do
      reversed_tail =
        messages
        |> Enum.reverse()
        |> Enum.take_while(&match?(%Message{role: :tool}, &1))
        |> Enum.reverse()

      {length(messages) - length(reversed_tail), reversed_tail}
    end
  end

  defp clip_one(message, tool_call_index, backend, opts, files_acc) do
    case read_file_original_path(message, tool_call_index) do
      path when is_binary(path) and path != "" ->
        {slice_read_file_message(message, path), files_acc}

      _missing ->
        offload_tool_message(message, backend, opts, files_acc)
    end
  end

  defp read_file_original_path(%Message{tool_call_id: id}, tool_call_index) when is_binary(id) do
    with %{} = call <- Map.get(tool_call_index, id),
         "read_file" <- to_string(Map.get(call, :name)),
         path when is_binary(path) <- MapAccess.get(Map.get(call, :args, %{}), :file_path) do
      path
    else
      _other -> nil
    end
  end

  defp read_file_original_path(_message, _tool_call_index), do: nil

  defp slice_read_file_message(%Message{} = message, path) do
    notice = String.replace(@read_file_truncation_notice, "%{file_path}", path)

    %{
      message
      | content:
          Offload.evicted_content(
            message,
            String.slice(Message.text(message), 0, 4_000) <> notice
          )
    }
  end

  defp offload_tool_message(%Message{} = message, backend, opts, files_acc) do
    content = Message.text(message)
    tool_call_id = message.tool_call_id || ID.uuidv7()

    prefix =
      Keyword.get(opts, :large_tool_results_prefix) ||
        Helpers.artifact_prefix(backend, "large_tool_results")

    file_path =
      String.trim_trailing(prefix, "/") <> "/" <> Offload.sanitize_tool_call_id(tool_call_id)

    write_opts =
      opts
      |> backend_opts()
      |> Offload.maybe_put_state_files(Keyword.get(opts, :state_key, :files), files_acc)

    case Filesystem.write(backend, file_path, content, write_opts) do
      %Filesystem.WriteResult{error: nil, files_update: files_update} ->
        replacement = Offload.tool_result_notice(tool_call_id, file_path, content)

        {%{message | content: Offload.evicted_content(message, replacement)},
         Offload.merge_files_update(files_acc, files_update)}

      _error ->
        {nil, files_acc}
    end
  end

  defp backend_opts(opts) do
    [
      state: Keyword.get(opts, :state, %{}) || %{},
      store: Keyword.get(opts, :store),
      runtime: Keyword.get(opts, :runtime)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp count_tokens(messages, :approximate) do
    case MessageUtils.count_tokens_approximately(messages) do
      {:ok, count} -> count
      _error -> approximate_tokens(messages)
    end
  end

  defp count_tokens(messages, counter) when is_function(counter, 1), do: counter.(messages)
  defp count_tokens(messages, _counter), do: approximate_tokens(messages)

  defp approximate_tokens(messages) do
    messages
    |> Enum.map_join("\n", &Message.text/1)
    |> String.length()
    |> div(@chars_per_token)
  end

  defp build_tool_call_index(messages) do
    Enum.reduce(messages, %{}, fn
      %Message{role: :assistant, tool_calls: calls}, acc when is_list(calls) ->
        Enum.reduce(calls, acc, fn call, acc ->
          case Map.get(call, :id) do
            id when is_binary(id) and id != "" -> Map.put(acc, id, call)
            _missing -> acc
          end
        end)

      _message, acc ->
        acc
    end)
  end

  defp ensure_id(%Message{id: nil} = message), do: %{message | id: ID.uuidv7()}
  defp ensure_id(message), do: message
end
