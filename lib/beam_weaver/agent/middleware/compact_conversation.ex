defmodule BeamWeaver.Agent.Middleware.CompactConversation do
  @moduledoc "Manual DeepAgents conversation compaction tool middleware."

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Utils
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Overwrite

  import BeamWeaver.Agent.Middleware.Helpers,
    only: [
      append_prompt: 2,
      artifact_prefix: 2,
      maybe_put_files_update: 3,
      state_value: 2,
      state_value: 3
    ]

  @system_prompt """
  ## Compact conversation Tool `compact_conversation`

  You have access to a `compact_conversation` tool. This tool refreshes your context window to reduce context bloat and costs.

  You should use the tool when:
  - The user asks to move on to a completely new task for which previous context is likely irrelevant.
  - You have finished extracting or synthesizing a result and previous working context is no longer needed.
  """

  defstruct model: nil,
            backend: State.new(),
            state_key: :files,
            event_key: :_summarization_event,
            minimum_messages: 20,
            keep_messages: 8,
            conversation_history_prefix: "/conversation_history",
            system_prompt: @system_prompt

  def new(opts \\ []) do
    backend = Keyword.get(opts, :backend, State.new())

    %__MODULE__{
      model: Keyword.fetch!(opts, :model),
      backend: backend,
      state_key: Keyword.get(opts, :state_key, :files),
      event_key: Keyword.get(opts, :event_key, :_summarization_event),
      minimum_messages: Keyword.get(opts, :minimum_messages, 20),
      keep_messages: Keyword.get(opts, :keep_messages, 8),
      conversation_history_prefix:
        Keyword.get(
          opts,
          :conversation_history_prefix,
          artifact_prefix(backend, "conversation_history")
        ),
      system_prompt: Keyword.get(opts, :system_prompt, @system_prompt)
    }
  end

  @impl true
  def name(_middleware), do: :deepagents_compact_conversation

  @impl true
  def state_schema(%__MODULE__{event_key: event_key}) do
    %{event_key => Graph.private_channel(BeamWeaver.Graph.Channels.LastValue)}
  end

  @impl true
  def tools(%__MODULE__{} = middleware) do
    [
      Tool.from_function!(
        name: "compact_conversation",
        description:
          "Compact the conversation by summarizing older messages into a concise summary. This tool takes no arguments.",
        input_schema: %{"type" => "object", "properties" => %{}},
        injected: %{state: :state, tool_call_id: :tool_call_id, tool_runtime: :tool_runtime},
        handler: fn input, _opts -> run_compact(middleware, input) end,
        metadata: %{integration: :deepagents, kind: :compact_conversation}
      )
    ]
  end

  def before_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = state_value(state, :messages, []) || []

    case state_value(state, middleware.event_key) do
      event when is_map(event) -> apply_event(middleware, messages, event)
      _missing -> %{}
    end
  end

  def wrap_model_call(%__MODULE__{system_prompt: nil}, %ModelRequest{} = request, handler),
    do: handler.(request)

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    request
    |> ModelRequest.override(system_message: append_prompt(request.system_message, middleware.system_prompt))
    |> handler.()
  end

  defp run_compact(%__MODULE__{} = middleware, input) do
    state = value(input, :state, %{}) || %{}
    messages = state_value(state, :messages, []) || []
    tool_call_id = value(input, :tool_call_id)

    if eligible?(middleware, messages) do
      compact_messages(middleware, input, messages, tool_call_id)
    else
      tool_command(
        "Nothing to compact yet - conversation is within the token budget.",
        tool_call_id
      )
    end
  end

  defp compact_messages(%__MODULE__{} = middleware, input, messages, tool_call_id) do
    cutoff = safe_cutoff(messages, max(length(messages) - middleware.keep_messages, 0))

    if cutoff <= 0 do
      tool_command(
        "Nothing to compact yet - conversation is within the token budget.",
        tool_call_id
      )
    else
      {to_summarize, _recent} = Enum.split(messages, cutoff)

      with {:ok, rendered} <- render_messages(to_summarize),
           {:ok, summary} <- create_summary(middleware, rendered),
           {file_path, files_update} <- offload_history(middleware, input, rendered) do
        summary_message =
          Message.user("Conversation summary:\n" <> summary,
            id: ID.uuidv7(),
            metadata: %{conversation_history_path: file_path}
          )

        event = %{
          cutoff_index: cutoff,
          summary_message: summary_message,
          file_path: file_path
        }

        update =
          %{
            middleware.event_key => event,
            messages: [
              Message.tool(
                "Conversation compacted. Summarized #{length(to_summarize)} messages into a concise summary.",
                tool_call_id: tool_call_id,
                name: "compact_conversation"
              )
            ]
          }
          |> maybe_put_files_update(middleware.state_key, files_update)

        %Command{update: update}
      else
        {:error, reason} ->
          tool_command("Compaction failed: #{reason}", tool_call_id, status: "error")
      end
    end
  end

  defp apply_event(_middleware, messages, event) do
    summary_message = event_value(event, :summary_message)
    cutoff = event_value(event, :cutoff_index) || 0

    cond do
      not match?(%Message{}, summary_message) ->
        %{}

      Enum.any?(messages, &(&1.id == summary_message.id)) ->
        %{}

      cutoff <= 0 ->
        %{}

      true ->
        %{messages: Overwrite.new([summary_message | Enum.drop(messages, safe_cutoff(messages, cutoff))])}
    end
  end

  defp eligible?(%__MODULE__{minimum_messages: nil}, _messages), do: true

  defp eligible?(%__MODULE__{minimum_messages: minimum}, messages),
    do: length(messages) >= minimum

  defp create_summary(%__MODULE__{} = middleware, rendered) do
    prompt = Message.user("Summarize this conversation concisely:\n\n" <> rendered)

    case ChatModel.invoke(middleware.model, [prompt], metadata: %{lc_source: "compact_conversation"}) do
      {:ok, %Message{} = message} -> {:ok, Message.text(message)}
      {:error, error} -> {:error, error.message}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp offload_history(%__MODULE__{} = middleware, input, rendered) do
    file_path = middleware.conversation_history_prefix <> "/" <> ID.uuidv7() <> ".md"

    opts =
      input
      |> value(:tool_runtime)
      |> backend_opts(value(input, :state, %{}))

    case Filesystem.write(middleware.backend, file_path, rendered, opts) do
      %Filesystem.WriteResult{error: nil, files_update: files_update} -> {file_path, files_update}
      _error -> {nil, nil}
    end
  end

  defp render_messages(messages) do
    case Utils.get_buffer_string(messages) do
      {:ok, rendered} -> {:ok, rendered}
      _error -> {:ok, inspect(messages)}
    end
  end

  defp safe_cutoff(messages, index) when index >= length(messages), do: index

  defp safe_cutoff(messages, index) do
    case Enum.at(messages, index) do
      %Message{role: :tool, tool_call_id: id} when is_binary(id) ->
        case matching_assistant_index(messages, index, id) do
          nil -> skip_tool_messages(messages, index)
          assistant_index -> assistant_index
        end

      _message ->
        index
    end
  end

  defp matching_assistant_index(messages, index, tool_call_id) do
    messages
    |> Enum.take(index)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: :assistant, tool_calls: calls}, assistant_index} when is_list(calls) ->
        if Enum.any?(calls, &(tool_call_id(&1) == tool_call_id)), do: assistant_index

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

  defp tool_call_id(%{id: id}) when is_binary(id), do: id
  defp tool_call_id(%{call_id: id}) when is_binary(id), do: id
  defp tool_call_id(%{provider_id: id}) when is_binary(id), do: id
  defp tool_call_id(%{"id" => id}) when is_binary(id), do: id
  defp tool_call_id(%{"call_id" => id}) when is_binary(id), do: id
  defp tool_call_id(%{"provider_id" => id}) when is_binary(id), do: id
  defp tool_call_id(_call), do: nil

  defp tool_command(content, tool_call_id, opts \\ []) do
    metadata =
      if Keyword.get(opts, :status) == "error",
        do: %{status: "error", error_type: :compact_conversation_failed},
        else: %{status: "success"}

    %Command{
      update: %{
        messages: [
          Message.tool(content,
            tool_call_id: tool_call_id,
            name: "compact_conversation",
            metadata: metadata
          )
        ]
      }
    }
  end

  defp backend_opts(%{store: store, runtime: runtime}, state),
    do: [state: state, store: store, runtime: runtime]

  defp backend_opts(_runtime, state), do: [state: state]

  defp event_value(event, key), do: Map.get(event, key) || Map.get(event, to_string(key))

  defp value(map, key, default \\ nil)
  defp value(nil, _key, default), do: default
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, to_string(key), default))
end
