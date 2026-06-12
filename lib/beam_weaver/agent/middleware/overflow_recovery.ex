defmodule BeamWeaver.Agent.Middleware.OverflowRecovery do
  @moduledoc """
  Read-side clipping for DeepAgents context-overflow recovery.

  The helper targets the preserved message suffix that ends with a consecutive
  batch of tool messages. Large generic tool results are offloaded to the
  filesystem backend; `read_file` results are head-sliced and point back to the
  original file path because the full data is already available there.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.Middleware.Offload
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Utils, as: MessageUtils
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Options

  @chars_per_token 4

  @too_large_tool_msg """
  Tool result too large, the result of this tool call %{tool_call_id} was saved in the filesystem at this path: %{file_path}

  You can read the result from the filesystem by using the read_file tool, but make sure to only read part of the result at a time.

  You can do this by specifying an offset and limit in the read_file tool call. For example, to read the first 100 lines, you can use the read_file tool with offset=0 and limit=100.

  Here is a preview showing the head and tail of the result (lines of the form `... [N lines truncated] ...` indicate omitted lines in the middle of the content):

  %{content_sample}
  """

  @read_file_truncation_notice """

  [Output was truncated due to context window size limits. The full content is at %{file_path}. Use read_file with offset and limit parameters to retrieve specific portions. For example, to read the first 100 lines, call read_file with file_path='%{file_path}', offset=0, limit=100.]
  """

  defstruct messages: [],
            replacements: [],
            files_update: nil,
            clipped?: false,
            backend: nil,
            keep: {:messages, 8},
            max_input_tokens: nil,
            token_counter: :approximate,
            large_tool_results_prefix: nil,
            state_key: :files,
            retry?: true

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
          retry?: boolean()
        }

  def new(opts \\ []) do
    %__MODULE__{
      backend: Keyword.get(opts, :backend, State.new()),
      keep: Keyword.get(opts, :keep, {:messages, 8}),
      max_input_tokens: Keyword.get(opts, :max_input_tokens),
      token_counter: Keyword.get(opts, :token_counter, :approximate),
      large_tool_results_prefix: Keyword.get(opts, :large_tool_results_prefix),
      state_key: Keyword.get(opts, :state_key, :files),
      retry?: Keyword.get(opts, :retry, true)
    }
  end

  @impl true
  def name(_middleware), do: :deepagents_overflow_clip

  def wrap_model_call(%__MODULE__{retry?: false}, %ModelRequest{} = request, handler),
    do: handler.(request)

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    case handler.(request) do
      {:error, %Error{} = error} = result ->
        if context_overflow?(error) do
          retry_after_clip(middleware, request, handler, result)
        else
          result
        end

      other ->
        other
    end
  end

  @doc "Derives the tail clipping threshold from a DeepAgents keep setting."
  def derive_threshold_tokens({:tokens, value}, _max_input_tokens)
      when is_integer(value),
      do: value

  def derive_threshold_tokens({:fraction, value}, max_input_tokens)
      when is_number(value) do
    case max_input_tokens do
      limit when is_integer(limit) and limit > 0 -> trunc(limit * value)
      _missing -> 5_000
    end
  end

  def derive_threshold_tokens({kind, _value}, _max_input_tokens) when is_binary(kind) do
    Options.atom_enum!("keep kind", kind, [:tokens, :fraction, :messages])
  end

  def derive_threshold_tokens(_keep, _max_input_tokens), do: 5_000

  @doc """
  Clips an oversized trailing tool-message batch.

  Options:

  - `:keep` - context keep setting, default `{:messages, 8}`.
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

  @doc "Task-backed async variant of `clip_tail/3`."
  def aclip_tail(messages, backend \\ State.new(), opts \\ []),
    do: Task.async(fn -> clip_tail(messages, backend, opts) end)

  defp retry_after_clip(%__MODULE__{} = middleware, %ModelRequest{} = request, handler, original) do
    backend = middleware.backend || State.new()

    result =
      clip_tail(request.messages, backend,
        keep: middleware.keep,
        max_input_tokens: middleware.max_input_tokens,
        token_counter: middleware.token_counter,
        large_tool_results_prefix: middleware.large_tool_results_prefix,
        state: request.state || %{},
        runtime: request.runtime,
        state_key: middleware.state_key
      )

    if result.clipped? do
      request
      |> ModelRequest.override(%{
        messages: result.messages,
        state: retry_state(request.state, middleware.state_key, result.files_update)
      })
      |> handler.()
    else
      original
    end
  end

  defp retry_state(state, _state_key, nil), do: state || %{}

  defp retry_state(state, state_key, files_update) when is_map(files_update) do
    state = state || %{}
    Map.put(state, state_key, files_update)
  end

  defp context_overflow?(%Error{type: :context_overflow}), do: true

  defp context_overflow?(%Error{message: message}) when is_binary(message) do
    normalized = String.downcase(message)

    String.contains?(normalized, "context window") or
      String.contains?(normalized, "context length") or
      String.contains?(normalized, "maximum context") or
      String.contains?(normalized, "prompt is too long")
  end

  defp context_overflow?(_error), do: false

  defp maybe_clip_tail(messages, backend, opts, start, tail) do
    threshold =
      derive_threshold_tokens(
        Keyword.get(opts, :keep, {:messages, 8}),
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
    case Map.get(tool_call_index, id) do
      %{} = call ->
        if tool_name(call) == "read_file" do
          path = call |> tool_args() |> arg_value(:file_path)
          if is_binary(path), do: path
        end

      _missing ->
        nil
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
    tool_call_id = message.tool_call_id || "unknown"

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
        replacement =
          Offload.format_notice(@too_large_tool_msg,
            tool_call_id: tool_call_id,
            file_path: file_path,
            content_sample: Offload.content_preview(content)
          )

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
          case call_id(call) do
            id when is_binary(id) and id != "" -> Map.put(acc, id, call)
            _missing -> acc
          end
        end)

      _message, acc ->
        acc
    end)
  end

  defp call_id(call) when is_map(call), do: Map.get(call, :id)
  defp call_id(_call), do: nil

  defp tool_name(call) when is_map(call),
    do: to_string(Map.get(call, :name))

  defp tool_args(call) when is_map(call), do: Map.get(call, :args, %{})

  defp arg_value(args, key) when is_map(args),
    do: BeamWeaver.MapAccess.get(args, key)

  defp arg_value(_args, _key), do: nil

  defp ensure_id(%Message{id: nil} = message), do: %{message | id: ID.uuidv7()}
  defp ensure_id(message), do: message
end
