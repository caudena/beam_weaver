defmodule BeamWeaver.Agent.Middleware.ContextEditing do
  @moduledoc """
  Applies explicit message edits before model calls.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Overwrite

  defmodule ClearToolUses do
    @moduledoc """
    Native context edit that clears older tool outputs before model calls.
    """

    defstruct trigger: 100_000,
              clear_at_least: 0,
              keep: 3,
              clear_tool_inputs: false,
              exclude_tools: [],
              placeholder: "[cleared]"

    def new(opts \\ []) do
      %__MODULE__{
        trigger: Keyword.get(opts, :trigger, 100_000),
        clear_at_least: Keyword.get(opts, :clear_at_least, 0),
        keep: Keyword.get(opts, :keep, 3),
        clear_tool_inputs: Keyword.get(opts, :clear_tool_inputs, false),
        exclude_tools: Keyword.get(opts, :exclude_tools, []),
        placeholder: Keyword.get(opts, :placeholder, "[cleared]")
      }
    end
  end

  defstruct editor: nil,
            edits: [],
            token_count_method: :approximate

  def new(opts \\ []) do
    if Keyword.has_key?(opts, :editor) do
      %__MODULE__{editor: Keyword.fetch!(opts, :editor)}
    else
      %__MODULE__{
        edits: Keyword.get(opts, :edits, [ClearToolUses.new(opts)]),
        token_count_method: opts |> Keyword.get(:token_count_method, :approximate) |> normalize_counter()
      }
    end
  end

  @impl true
  def name(_middleware), do: :context_editing

  def wrap_model_call(%__MODULE__{edits: []}, %ModelRequest{} = request, handler),
    do: handler.(request)

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    edited =
      Enum.reduce(middleware.edits, request.messages || [], fn edit, messages ->
        apply_edit(edit, messages, request, middleware)
      end)

    request
    |> ModelRequest.override(messages: edited)
    |> handler.()
  end

  def before_model(%__MODULE__{editor: nil}, _state, _runtime), do: %{}

  def before_model(%__MODULE__{editor: editor}, state, runtime) do
    messages = State.messages(state)
    edited = edit(editor, messages, state, runtime)
    if edited == messages, do: %{}, else: %{messages: Overwrite.new(edited)}
  end

  defp edit(fun, messages, state, runtime) when is_function(fun, 3),
    do: fun.(messages, state, runtime)

  defp edit(fun, messages, _state, _runtime) when is_function(fun, 1), do: fun.(messages)

  defp edit({module, function, args}, messages, state, runtime),
    do: apply(module, function, [messages, state, runtime | args])

  def clear_tool_uses(messages, opts \\ []) do
    apply_clear_tool_uses(ClearToolUses.new(opts), messages, fn value ->
      LanguageModel.count_tokens(:approximate, value)
    end)
  end

  def keep_recent_tool_context(messages, limit) do
    kept_tool_ids =
      messages
      |> Enum.filter(&match?(%Message{role: :tool}, &1))
      |> Enum.reverse()
      |> Enum.take(max(limit, 0))
      |> Enum.map(& &1.tool_call_id)
      |> MapSet.new()

    messages
    |> Enum.flat_map(&keep_message_with_tool_ids(&1, kept_tool_ids))
  end

  defp keep_message_with_tool_ids(%Message{role: :tool, tool_call_id: id} = message, ids) do
    if MapSet.member?(ids, id), do: [message], else: []
  end

  defp keep_message_with_tool_ids(%Message{role: :assistant, tool_calls: calls} = message, ids)
       when calls != [] do
    kept_calls = Enum.filter(calls, fn call -> MapSet.member?(ids, tool_call_id(call)) end)

    cond do
      kept_calls != [] ->
        [%{message | tool_calls: kept_calls}]

      empty_assistant_content?(message.content) ->
        []

      true ->
        [%{message | tool_calls: []}]
    end
  end

  defp keep_message_with_tool_ids(message, _ids), do: [message]

  defp tool_call_id(call) when is_map(call),
    do:
      Map.get(call, :id) ||
        Map.get(call, :call_id)

  defp tool_call_id(_call), do: nil

  defp empty_assistant_content?(content), do: content in [nil, "", []]

  defp apply_edit(%ClearToolUses{} = edit, messages, %ModelRequest{} = request, middleware) do
    apply_clear_tool_uses(edit, messages, fn value ->
      count_tokens(value, request, middleware)
    end)
  end

  defp apply_edit(fun, messages, %ModelRequest{}, _middleware) when is_function(fun, 1),
    do: fun.(messages)

  defp apply_edit({module, function, args}, messages, %ModelRequest{} = request, _middleware),
    do: apply(module, function, [messages, request | args])

  defp apply_edit(_edit, messages, _request, _middleware), do: messages

  defp apply_clear_tool_uses(%ClearToolUses{} = edit, messages, count_tokens) do
    messages = List.wrap(messages)

    with {:ok, tokens} <- count_tokens.(messages),
         true <- tokens > edit.trigger do
      candidates =
        messages
        |> Enum.with_index()
        |> Enum.filter(fn
          {%Message{role: :tool}, _index} -> true
          _other -> false
        end)
        |> drop_kept_tool_results(edit.keep)

      clear_candidates(edit, messages, candidates, tokens, count_tokens)
    else
      _other -> messages
    end
  end

  defp drop_kept_tool_results(candidates, keep) when keep >= length(candidates), do: []

  defp drop_kept_tool_results(candidates, keep) when keep > 0,
    do: Enum.drop(candidates, -keep)

  defp drop_kept_tool_results(candidates, _keep), do: candidates

  defp clear_candidates(edit, messages, candidates, original_tokens, count_tokens) do
    Enum.reduce_while(candidates, {messages, 0}, fn {%Message{} = tool_message, index}, {acc, _cleared_tokens} ->
      next = maybe_clear_tool_message(edit, acc, index, tool_message)

      cleared_tokens =
        case count_tokens.(next) do
          {:ok, tokens} -> max(0, original_tokens - tokens)
          _error -> 0
        end

      if edit.clear_at_least > 0 and cleared_tokens >= edit.clear_at_least do
        {:halt, {next, cleared_tokens}}
      else
        {:cont, {next, cleared_tokens}}
      end
    end)
    |> elem(0)
  end

  defp maybe_clear_tool_message(%ClearToolUses{} = edit, messages, index, tool_message) do
    with false <- cleared?(tool_message),
         {:ok, assistant_index, assistant, tool_call} <-
           matching_tool_call(messages, index, tool_message),
         false <- excluded_tool?(edit, tool_message, tool_call) do
      messages
      |> List.replace_at(index, cleared_tool_message(tool_message, edit))
      |> maybe_clear_tool_inputs(edit, assistant_index, assistant, tool_message.tool_call_id)
    else
      _other -> messages
    end
  end

  defp cleared?(%Message{response_metadata: metadata}) do
    metadata = metadata || %{}
    context = Map.get(metadata, :context_editing) || %{}
    Map.get(context, :cleared) == true
  end

  defp matching_tool_call(messages, index, %Message{tool_call_id: id}) do
    messages
    |> Enum.take(index)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: :assistant, tool_calls: calls} = message, assistant_index} ->
        case Enum.find(calls || [], &(tool_call_id(&1) == id)) do
          nil -> nil
          call -> {:ok, assistant_index, message, call}
        end

      _other ->
        nil
    end)
    |> case do
      nil -> :error
      result -> result
    end
  end

  defp excluded_tool?(%ClearToolUses{exclude_tools: excluded}, %Message{name: name}, tool_call) do
    tool_name = name || Map.get(tool_call, :name)
    to_string(tool_name) in Enum.map(excluded, &to_string/1)
  end

  defp cleared_tool_message(%Message{} = message, %ClearToolUses{} = edit) do
    metadata =
      (message.response_metadata || %{})
      |> Map.put(:context_editing, %{cleared: true, strategy: :clear_tool_uses})

    %{message | content: edit.placeholder, artifacts: [], response_metadata: metadata}
  end

  defp maybe_clear_tool_inputs(
         messages,
         %ClearToolUses{clear_tool_inputs: false},
         _index,
         _assistant,
         _id
       ),
       do: messages

  defp maybe_clear_tool_inputs(
         messages,
         %ClearToolUses{},
         assistant_index,
         assistant,
         tool_call_id
       ) do
    calls =
      Enum.map(assistant.tool_calls || [], fn call ->
        if tool_call_id(call) == tool_call_id do
          clear_call_args(call)
        else
          call
        end
      end)

    response_metadata = assistant.response_metadata || %{}

    metadata =
      response_metadata
      |> Map.get(:context_editing, %{})
      |> Map.put(:cleared_tool_inputs, [tool_call_id])
      |> then(&Map.put(response_metadata, :context_editing, &1))

    List.replace_at(messages, assistant_index, %{
      assistant
      | tool_calls: calls,
        response_metadata: metadata
    })
  end

  defp clear_call_args(call) do
    Map.put(call, :args, %{})
  end

  defp count_tokens(messages, %ModelRequest{} = request, %__MODULE__{token_count_method: :model}) do
    LanguageModel.count_tokens(request.model, prompt_messages(request.system_message) ++ messages, tools: request.tools)
  end

  defp count_tokens(messages, _request, _middleware),
    do: LanguageModel.count_tokens(:approximate, messages)

  defp prompt_messages(nil), do: []
  defp prompt_messages(messages) when is_list(messages), do: messages
  defp prompt_messages(%Message{} = message), do: [message]

  defp normalize_counter(value) when value in [:approximate, "approximate"], do: :approximate
  defp normalize_counter(value) when value in [:model, "model"], do: :model

  defp normalize_counter(value) do
    raise ArgumentError, "invalid context editing token_count_method: #{inspect(value)}"
  end
end
