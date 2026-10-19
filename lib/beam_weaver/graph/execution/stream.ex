defmodule BeamWeaver.Graph.Execution.Stream do
  @moduledoc false

  # Sends a run's events to its stream sink as they happen. Live and collected
  # streams both read the sink, so this is the only path events take. A run
  # without a sink (`invoke/3`, `resume/3`) builds and sends nothing.

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.Execution.Namespace
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Stream, as: BWStream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Sink

  @modes [
    :events,
    :values,
    :updates,
    :custom,
    :messages,
    :tools,
    :checkpoints,
    :tasks,
    :debug,
    :lifecycle
  ]

  # `:events` selects every event; anything else is one mode or a list of them.
  @spec normalize_modes(term()) :: {:ok, MapSet.t(atom())} | {:error, Error.t()}
  def normalize_modes(%MapSet{} = modes), do: modes |> MapSet.to_list() |> normalize_modes()
  def normalize_modes(mode) when is_atom(mode), do: normalize_modes([mode])

  def normalize_modes([_ | _] = modes) do
    case Enum.reject(modes, &(&1 in @modes)) do
      [] -> {:ok, MapSet.new(modes)}
      invalid -> {:error, invalid_modes(invalid)}
    end
  end

  def normalize_modes(modes), do: {:error, invalid_modes(modes)}

  # `:debug` also selects tasks and checkpoints. An `Error` event always passes,
  # so a failed run is visible whatever was selected.
  @spec selected?(MapSet.t(atom()), term()) :: boolean()
  def selected?(_modes, %Events.Error{}), do: true
  def selected?(modes, event), do: mode_selected?(modes, BWStream.event_mode(event))

  @spec emit_tasks(map(), list()) :: :ok
  def emit_tasks(%{stream_sink: nil}, _task_events), do: :ok

  def emit_tasks(run, task_events) do
    for {:task, %Events.Task{} = event} <- task_events do
      emit(run, event, node: event.node, task_id: event.task_id, step: event.step || run.step)
    end

    :ok
  end

  # A finished step: the messages it added, the update keyed by the nodes that
  # ran, and the whole state after it.
  @spec emit_step(map(), [term()], map(), map()) :: :ok
  def emit_step(%{stream_sink: nil}, _ready, _update, _state), do: :ok

  def emit_step(run, ready, update, state) do
    update = ChannelMerge.public_update(update)

    if mode_selected?(run.stream_modes, :messages) do
      update
      |> messages_from_update()
      |> Enum.each(&emit(run, %Events.Message{message: &1}))
    end

    if mode_selected?(run.stream_modes, :updates) do
      public_update = public_state(run, update)
      emit(run, %Events.GraphUpdate{update: Map.new(ready, &{TaskRequest.name(&1), public_update})})
    end

    if mode_selected?(run.stream_modes, :values) do
      emit(run, %Events.GraphValue{value: public_state(run, state)})
    end

    :ok
  end

  @spec emit_checkpoint(map(), map(), map()) :: :ok
  def emit_checkpoint(%{stream_sink: nil}, _config, _state), do: :ok

  def emit_checkpoint(run, config, state) do
    if mode_selected?(run.stream_modes, :checkpoints) do
      emit(run, %Events.Checkpoint{config: config, values: public_state(run, state), step: run.step})
    end

    :ok
  end

  # The `stream_writer` of a node's runtime: every value the node writes is an
  # event of its task, sent at once. An envelope passes through as it is.
  @spec writer(map(), String.t(), String.t()) :: (term() -> :ok)
  def writer(%{stream_sink: nil}, _node, _task_id), do: fn _value -> :ok end

  def writer(run, node, task_id) do
    fn
      %Envelope{event: event} = envelope ->
        if selected?(run.stream_modes, event), do: Sink.emit(run.stream_sink, envelope)
        :ok

      value ->
        emit(run, value, node: node, task_id: task_id)
    end
  end

  @spec task_event(atom(), String.t(), term(), non_neg_integer(), String.t(), String.t()) ::
          {:task, Events.Task.t()}
  def task_event(kind, node, payload, step, task_id, path) do
    {:task,
     %Events.Task{
       kind: kind,
       node: node,
       payload: payload,
       step: step,
       task_id: task_id,
       path: path
     }}
  end

  defp emit(run, value, opts \\ []) do
    event = BWStream.IntoEvent.into_event(value)

    if selected?(run.stream_modes, event) do
      envelope_opts =
        Keyword.merge(
          [run_id: run.run_id, graph: run.compiled.name, step: run.step, namespace: namespace(run)],
          opts
        )

      Sink.emit(run.stream_sink, BWStream.envelope(event, envelope_opts))
    end

    :ok
  end

  defp mode_selected?(modes, mode) do
    MapSet.member?(modes, :events) or MapSet.member?(modes, mode) or
      (mode in [:tasks, :checkpoints] and MapSet.member?(modes, :debug))
  end

  defp invalid_modes(modes) do
    Error.new(:invalid_stream_mode, "stream_mode must be a stream mode or a list of them", %{
      stream_mode: modes,
      allowed: @modes
    })
  end

  # A step's update holds the messages as they were written, by every node
  # that wrote them: a string or a map becomes a message, and removal markers
  # are left out.
  defp messages_from_update(update) do
    for written <- List.wrap(MapAccess.get(update, :messages, [])),
        value <- List.wrap(written),
        {:ok, message} <- [Message.from(value)],
        do: message
  end

  defp namespace(run) do
    run.config
    |> Map.get("configurable", Map.get(run.config, :configurable, %{}))
    |> Map.get("checkpoint_ns", "")
    |> Namespace.recast()
    |> Namespace.normalize()
  end

  defp public_state(run, state), do: ChannelLookup.public_state(run.compiled.graph, state)
end
