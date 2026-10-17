defmodule BeamWeaver.Agent.Middleware.CompactConversation do
  @moduledoc """
  Middleware that adds a `compact_conversation` tool, so the model can compact
  its conversation on demand.

  The tool summarizes older messages with the configured model, keeps the most
  recent ones, and saves the summarized messages to a file. The summary takes
  their place before the next model call, unless something rewrote the thread
  in between, such as a `Summarization` listed before this middleware. The
  pending compaction is saved with the thread (with a checkpointer), so a run
  that pauses or stops after the tool call applies it, once, when it continues.

  Options:

    * `:model` - the model that writes the summary. Required.
    * `:minimum_messages` - the tool does nothing until the thread has this
      many messages (20 by default; `nil` for no minimum).
    * `:keep_messages` - how many of the newest messages to keep word for word
      (8 by default).
    * `:backend` - the filesystem the summarized messages are saved to.
    * `:conversation_history_prefix` - the directory for those files.
    * `:system_prompt` - the prompt section that tells the model about the
      tool; `nil` leaves it out.

  The `compact_conversation` agent declaration adds this middleware and, after
  it, automatic summarization (`BeamWeaver.Agent.Middleware.Summarization`),
  configured separately under its `summarization:` option.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.Helpers
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
  alias BeamWeaver.MapAccess
  alias BeamWeaver.MapShape

  import BeamWeaver.Agent.Middleware.Helpers, only: [append_prompt: 2, artifact_prefix: 2]

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

  @options [
    :model,
    :backend,
    :state_key,
    :event_key,
    :minimum_messages,
    :keep_messages,
    :conversation_history_prefix,
    :system_prompt
  ]

  def new(opts \\ []) do
    validate_options!(opts)
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

  defp validate_options!(opts) do
    case Keyword.keys(opts) -- @options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "CompactConversation doesn't take #{inspect(unknown)}; its options are #{inspect(@options)}. " <>
                "Settings for automatic summarization go under `summarization:` in the `compact_conversation` declaration."
    end
  end

  @impl true
  def name(_middleware), do: :deepagents_compact_conversation

  @impl true
  def state_schema(%__MODULE__{event_key: event_key}) do
    %{event_key => Graph.private_channel(BeamWeaver.Graph.Channels.LastValue, checkpoint: true)}
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

  @impl true
  def before_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = Map.get(state, :messages, []) || []

    case Map.get(state, middleware.event_key) do
      event when is_map(event) -> apply_event(middleware, messages, event)
      _missing -> %{}
    end
  end

  @impl true
  def wrap_model_call(%__MODULE__{system_prompt: nil}, %ModelRequest{} = request, handler),
    do: handler.(request)

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    request
    |> ModelRequest.override(system_message: append_prompt(request.system_message, middleware.system_prompt))
    |> handler.()
  end

  defp run_compact(%__MODULE__{} = middleware, input) do
    state = MapAccess.get(input, :state, %{}) || %{}
    messages = Map.get(state, :messages, []) || []
    tool_call_id = MapAccess.get(input, :tool_call_id)

    cutoff =
      if eligible?(middleware, messages),
        do: Helpers.safe_cut_index(messages, max(length(messages) - middleware.keep_messages, 0)),
        else: 0

    if cutoff <= 0 do
      tool_command("Nothing to compact yet - conversation is within the token budget.", tool_call_id)
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
          message_ids: Enum.map(to_summarize, & &1.id),
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
          |> MapShape.put_present(middleware.state_key, files_update)

        %Command{update: update}
      else
        {:error, reason} ->
          tool_command("Compaction failed: #{reason}", tool_call_id, status: "error")
      end
    end
  end

  # The tool's event applies once, before the next model call: its summary
  # replaces the messages it covers, and the event is cleared. When the thread
  # no longer starts with those messages, because automatic summarization or
  # another edit rewrote it after the tool ran, the event is only cleared: its
  # cut no longer fits the thread.
  defp apply_event(middleware, messages, event) do
    summary_message = event_value(event, :summary_message)
    cutoff = event_value(event, :cutoff_index) || 0
    cleared = %{middleware.event_key => nil}

    if match?(%Message{}, summary_message) and cutoff > 0 and
         covered_messages?(messages, cutoff, event_value(event, :message_ids)) do
      recent =
        messages
        |> Enum.drop(Helpers.safe_cut_index(messages, cutoff))
        |> Utils.strip_reasoning_blocks()

      Map.put(cleared, :messages, Overwrite.new([summary_message | recent]))
    else
      cleared
    end
  end

  defp covered_messages?(messages, cutoff, ids) when is_list(ids) and length(ids) == cutoff,
    do: messages |> Enum.take(cutoff) |> Enum.map(& &1.id) == ids

  defp covered_messages?(_messages, _cutoff, _ids), do: false

  defp eligible?(%__MODULE__{minimum_messages: nil}, _messages), do: true

  defp eligible?(%__MODULE__{minimum_messages: minimum}, messages),
    do: length(messages) >= minimum

  defp create_summary(%__MODULE__{} = middleware, rendered) do
    prompt = Message.user("Summarize this conversation concisely:\n\n" <> rendered)

    case ChatModel.invoke(middleware.model, [prompt], trace_metadata: %{source: :compact_conversation}) do
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
      |> MapAccess.get(:tool_runtime)
      |> backend_opts(MapAccess.get(input, :state, %{}))

    case Filesystem.write(middleware.backend, file_path, rendered, opts) do
      %Filesystem.WriteResult{error: nil, files_update: files_update} -> {file_path, files_update}
      _error -> {nil, nil}
    end
  end

  defp render_messages(messages) do
    case Utils.buffer_string(messages) do
      {:ok, rendered} -> {:ok, rendered}
      _error -> {:ok, inspect(messages)}
    end
  end

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
end
