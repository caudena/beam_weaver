defmodule BeamWeaver.Graph.Execution.Stream do
  @moduledoc """
  Stream event helpers for compiled graph execution.

  Internally this module uses typed `BeamWeaver.Stream` events. Legacy graph
  stream modes are formatted at the boundary to preserve existing public shapes.
  """

  alias BeamWeaver.Graph.Execution.ChannelState
  alias BeamWeaver.Graph.Execution.Namespace
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Stream, as: BWStream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  @stream_modes [
    :values,
    :updates,
    :custom,
    :messages,
    :tools,
    :checkpoints,
    :tasks,
    :debug,
    :events
  ]

  @spec normalize_modes(atom() | String.t() | [atom() | String.t()]) :: MapSet.t(atom())
  def normalize_modes(mode) when mode in @stream_modes, do: MapSet.new([mode])

  def normalize_modes(mode) when is_binary(mode),
    do: normalize_modes(BWStream.normalize_mode(mode))

  def normalize_modes(modes) when is_list(modes), do: MapSet.new(modes, &normalize_mode/1)

  @spec add_step_events(list(), map(), [term()], map(), map()) :: list()
  def add_step_events(events, run, ready, update, state) do
    message_events = message_stream_events(run, update)

    update_events =
      []
      |> maybe_event(
        run,
        :updates,
        %Events.GraphUpdate{
          update: Map.new(ready_names(ready), fn node -> {node, public_state(run, update)} end)
        }
      )
      |> maybe_event(run, :values, %Events.GraphValue{value: public_state(run, state)})

    events ++ message_events ++ update_events
  end

  @spec checkpoint_events(map(), map(), map()) :: list()
  def checkpoint_events(run, config, state) do
    maybe_event(
      [],
      run,
      :checkpoints,
      %Events.Checkpoint{config: config, values: public_state(run, state), step: run.step}
    )
  end

  @spec add_events(list(), list(), map()) :: list()
  def add_events(events, new_events, run) do
    formatted =
      Enum.flat_map(new_events, fn
        {:task, payload} ->
          maybe_event([], run, :tasks, event_for(payload, :tasks))

        {:custom, payload} ->
          custom_events(payload, run)

        other ->
          [other]
      end)

    events ++ formatted
  end

  @spec task_event(atom(), String.t(), term(), non_neg_integer(), String.t(), String.t() | nil) ::
          {:task, Events.Task.t()}
  def task_event(kind, node, payload, step, task_id, path) do
    {:task,
     %Events.Task{
       kind: kind,
       node: node,
       payload: payload,
       step: step,
       task_id: task_id,
       path: path || ""
     }}
  end

  @spec custom_event(term()) :: {:custom, term()}
  def custom_event(payload), do: {:custom, payload}

  defp custom_events(%Events.ToolStart{} = event, run), do: maybe_event([], run, :tools, event)
  defp custom_events(%Events.ToolDelta{} = event, run), do: maybe_event([], run, :tools, event)
  defp custom_events(%Events.ToolFinish{} = event, run), do: maybe_event([], run, :tools, event)
  defp custom_events(%Events.ToolError{} = event, run), do: maybe_event([], run, :tools, event)

  defp custom_events(%Envelope{} = envelope, run) do
    mode = BWStream.event_mode(envelope.event)

    if MapSet.member?(run.stream_modes, mode) or MapSet.member?(run.stream_modes, :events) or
         (mode in [:tasks, :checkpoints] and MapSet.member?(run.stream_modes, :debug)) do
      emit_to_sink(run, envelope)
      [BWStream.format(envelope, run.stream_modes)]
    else
      []
    end
  end

  defp custom_events(%Events.Message{} = event, run) do
    []
    |> maybe_event(run, :messages, event)
    |> maybe_event(run, :custom, %Events.Custom{payload: event})
  end

  defp custom_events(%Events.Custom{} = event, run), do: maybe_event([], run, :custom, event)

  defp custom_events(%{type: :tool_event} = payload, run) do
    maybe_event([], run, :tools, BeamWeaver.Stream.IntoEvent.into_event(payload))
  end

  defp custom_events(%{type: :message, message: message} = payload, run) do
    []
    |> maybe_event(run, :messages, %Events.Message{
      message: message,
      metadata: Map.get(payload, :metadata, %{})
    })
    |> maybe_event(run, :custom, %Events.Custom{payload: payload})
  end

  defp custom_events(%{type: :ui, message: ui_message}, run) do
    maybe_event([], run, :custom, %Events.Custom{payload: ui_message})
  end

  defp custom_events(payload, run) do
    maybe_event([], run, :custom, BeamWeaver.Stream.IntoEvent.into_event(payload))
  end

  defp message_stream_events(run, update) do
    update
    |> messages_from_update()
    |> Enum.reduce([], fn message, events ->
      maybe_event(events, run, :messages, %Events.Message{message: message})
    end)
  end

  defp messages_from_update(update) when is_map(update) do
    update
    |> Map.get(:messages, Map.get(update, "messages", []))
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp messages_from_update(_update), do: []

  defp maybe_event(events, run, mode, payload) do
    if MapSet.member?(run.stream_modes, mode) or
         MapSet.member?(run.stream_modes, :events) or
         (mode in [:tasks, :checkpoints] and MapSet.member?(run.stream_modes, :debug)) do
      [format_stream_event(run, mode, payload) | events]
    else
      events
    end
  end

  defp format_stream_event(run, mode, payload) do
    envelope =
      payload
      |> event_for(mode)
      |> BWStream.envelope(envelope_opts(run, payload))

    emit_to_sink(run, envelope)
    BWStream.format(envelope, run.stream_modes)
  end

  defp emit_to_sink(%{stream_sink: nil}, _envelope), do: :ok

  defp emit_to_sink(%{stream_sink: sink}, %Envelope{} = envelope) do
    BeamWeaver.Stream.Sink.emit(sink, envelope)
    :ok
  end

  defp emit_to_sink(_run, _envelope), do: :ok

  defp event_for(%Events.GraphUpdate{} = event, _mode), do: event
  defp event_for(%Events.GraphValue{} = event, _mode), do: event
  defp event_for(%Events.Message{} = event, _mode), do: event
  defp event_for(%Events.ToolStart{} = event, _mode), do: event
  defp event_for(%Events.ToolDelta{} = event, _mode), do: event
  defp event_for(%Events.ToolFinish{} = event, _mode), do: event
  defp event_for(%Events.ToolError{} = event, _mode), do: event
  defp event_for(%Events.Checkpoint{} = event, _mode), do: event
  defp event_for(%Events.Task{} = event, _mode), do: event
  defp event_for(%Events.Custom{} = event, _mode), do: event
  defp event_for(payload, :updates), do: %Events.GraphUpdate{update: payload}
  defp event_for(payload, :values), do: %Events.GraphValue{value: payload}
  defp event_for(payload, :messages), do: %Events.Message{message: payload}
  defp event_for(payload, :custom), do: %Events.Custom{payload: payload}
  defp event_for(payload, :tasks) when is_map(payload), do: struct(Events.Task, payload)

  defp event_for(payload, :checkpoints) when is_map(payload),
    do: struct(Events.Checkpoint, payload)

  defp event_for(payload, :tools),
    do: BeamWeaver.Stream.IntoEvent.into_event(%{type: :tool_event, payload: payload})

  defp envelope_opts(run, %Events.Task{} = event) do
    run
    |> base_envelope_opts()
    |> Keyword.put(:node, event.node)
    |> Keyword.put(:task_id, event.task_id)
    |> Keyword.put(:step, event.step || run.step)
  end

  defp envelope_opts(run, %Events.Checkpoint{} = event),
    do: Keyword.put(base_envelope_opts(run), :step, event.step || run.step)

  defp envelope_opts(run, _payload), do: base_envelope_opts(run)

  defp base_envelope_opts(run) do
    [
      run_id: run.run_id,
      graph: run.compiled.name,
      step: run.step,
      namespace: namespace(run)
    ]
  end

  defp namespace(run) do
    run.config
    |> Map.get("configurable", Map.get(run.config, :configurable, %{}))
    |> Map.get("checkpoint_ns", "")
    |> Namespace.recast()
    |> Namespace.normalize()
  end

  defp ready_names(ready), do: Enum.map(ready, &TaskRequest.name/1)

  defp public_state(%{compiled: %{graph: graph}}, state) when is_map(state),
    do: ChannelState.public_state(graph, state)

  defp public_state(_run, state), do: state

  defp normalize_mode(mode) when is_atom(mode), do: mode
  defp normalize_mode(mode) when is_binary(mode), do: BWStream.normalize_mode(mode)
end
