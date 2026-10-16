defmodule BeamWeaver.Graph.Compiled.Runtime do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.Runner
  alias BeamWeaver.Graph.Execution.Stream, as: ExecutionStream
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Stream, as: BWStream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Sink

  def invoke(compiled, input, opts) do
    with {:ok, input, opts} <- run_input(compiled, input, opts) do
      case Runner.execute(compiled, input, opts) do
        {:ok, result} -> {:ok, graph_output(compiled, result)}
        other -> run_result(other)
      end
    end
  end

  def stream_events(compiled, input, opts) do
    with {:ok, input, run_opts} <- run_input(compiled, input, opts),
         {:ok, modes} <- ExecutionStream.normalize_modes(Keyword.get(opts, :stream_mode, :events)) do
      run_opts =
        run_opts
        |> Keyword.put(:stream_mode, modes)
        |> Keyword.put_new_lazy(:run_id, &ID.uuidv7/0)

      if Keyword.get(opts, :live, false) do
        {:ok, event_stream(compiled, input, run_opts, fn _result -> :ok end)}
      else
        collect_events(compiled, input, run_opts)
      end
    end
  end

  def resume(compiled, resume, opts) do
    opts =
      opts
      |> Keyword.put(:resume, resume)
      |> rebase_time_travel_opts(compiled)

    compiled
    |> Runner.execute(%{}, opts)
    |> run_result()
  end

  def graph_input(%{graph: %{input_schema: input_schema}}, input) when is_map(input) do
    case schema_key_names(input_schema) do
      [] -> input
      keys -> Map.filter(input, fn {key, _value} -> to_string(key) in keys end)
    end
  end

  def graph_output(%{graph: %{output_schema: output_schema}}, output) when is_map(output) do
    case schema_key_names(output_schema) do
      [] -> output
      keys -> Map.filter(output, fn {key, _value} -> to_string(key) in keys end)
    end
  end

  def graph_output(_compiled, output), do: output

  def rebase_time_travel_opts(opts, compiled) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} when is_map(config) ->
        rebased = SubgraphRouter.rebase_time_travel_config(compiled, config)

        opts
        |> Keyword.put(:config, rebased)
        |> maybe_clear_rebased_pending_writes(config, rebased)

      _other ->
        opts
    end
  end

  defp run_input(compiled, %Command{} = command, opts) do
    opts =
      command
      |> CommandRouter.command_opts(opts)
      |> rebase_time_travel_opts(compiled)

    {:ok, graph_input(compiled, CommandRouter.command_update(command)), opts}
  end

  defp run_input(compiled, input, opts) when is_map(input) do
    {:ok, graph_input(compiled, CommandRouter.normalize_update(input)), rebase_time_travel_opts(opts, compiled)}
  end

  defp run_input(_compiled, _input, _opts),
    do: {:error, Error.new(:invalid_input, "graph input must be a map")}

  defp run_result({:ok, result}), do: {:ok, result}
  defp run_result({:interrupted, interrupt}), do: {:interrupted, interrupt}
  defp run_result({:parent_command, command}), do: CommandRouter.parent_command_error(command)
  defp run_result({:error, error}), do: {:error, error}

  # Without `live: true` the run streams exactly as a live one does and is read
  # to the end here, so both return the same events in the same order. The run
  # reports how it ended before its stream closes.
  defp collect_events(compiled, input, opts) do
    caller = self()
    ref = make_ref()

    report = fn
      {:ok, _output} -> send(caller, {ref, :ok})
      result -> send(caller, {ref, result})
    end

    events =
      compiled
      |> event_stream(input, opts, report)
      |> Enum.to_list()

    receive do
      {^ref, :ok} -> {:ok, events}
      {^ref, {:interrupted, interrupt}} -> {:interrupted, Map.put(interrupt, :events, events)}
      {^ref, result} -> run_result(result)
    after
      0 -> stream_failure(events)
    end
  end

  # The run never reported back, so the stream ended on the error that stopped
  # it, such as a crash or `stream_timeout:`.
  defp stream_failure(events) do
    case List.last(events) do
      %Envelope{event: %Events.Error{error: %Error{} = error}} -> {:error, error}
      _other -> {:error, Error.new(:stream_error, "graph stream ended without a result")}
    end
  end

  defp event_stream(compiled, input, opts, report) do
    modes = Keyword.fetch!(opts, :stream_mode)
    run_id = Keyword.fetch!(opts, :run_id)

    # The producer has no name, so events that don't come from a node keep
    # `node: nil`.
    producer =
      {:sink, nil,
       fn sink ->
         result = Runner.execute(compiled, input, Keyword.put(opts, :stream_sink, sink))
         report.(result)
         emit_outcome(sink, compiled, run_id, result)
       end}

    [producer]
    |> BWStream.mux(
      run_id: run_id,
      graph: compiled.name,
      metadata: Keyword.get(opts, :metadata, %{}),
      heartbeat: Keyword.get(opts, :heartbeat),
      max_buffer: Keyword.get(opts, :max_buffer, 256),
      overflow: Keyword.get(opts, :overflow, :block),
      timeout: Keyword.get(opts, :stream_timeout, :infinity),
      cancel_timeout: Keyword.get(opts, :cancel_timeout, 100),
      producer_supervisor: Keyword.get(opts, :producer_supervisor)
    )
    |> Elixir.Stream.filter(&ExecutionStream.selected?(modes, &1.event))
    |> Elixir.Stream.map(&BWStream.format(&1, modes))
  end

  defp emit_outcome(_sink, _compiled, _run_id, {:ok, _result}), do: :ok

  defp emit_outcome(sink, compiled, run_id, {:interrupted, interrupt}) do
    emit_debug(sink, compiled, run_id, %{type: :interrupt, interrupt: interrupt})
  end

  # The stream ends with an `Error` event: a top-level graph has no parent
  # for the command, so the run fails as `invoke/3` reports it.
  defp emit_outcome(_sink, _compiled, _run_id, {:parent_command, command}),
    do: CommandRouter.parent_command_error(command)

  defp emit_outcome(_sink, _compiled, _run_id, {:error, %Error{} = error}), do: {:error, error}

  defp emit_debug(sink, compiled, run_id, payload) do
    Sink.emit(sink, BWStream.envelope(BWStream.event(:debug, payload), run_id: run_id, graph: compiled.name))
    :ok
  end

  defp maybe_clear_rebased_pending_writes(opts, config, rebased) when config != rebased,
    do: Keyword.put(opts, :clear_pending_writes?, true)

  defp maybe_clear_rebased_pending_writes(opts, _config, _rebased), do: opts

  defp schema_key_names(nil), do: []

  defp schema_key_names(%{"properties" => properties}) when is_map(properties) do
    properties |> Map.keys() |> Enum.map(&to_string/1)
  end

  defp schema_key_names(%{properties: properties}) when is_map(properties) do
    properties |> Map.keys() |> Enum.map(&to_string/1)
  end

  defp schema_key_names(schema) when is_map(schema) do
    schema |> Map.keys() |> Enum.map(&to_string/1)
  end

  defp schema_key_names(_schema), do: []
end
