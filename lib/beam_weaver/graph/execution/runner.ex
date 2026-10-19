defmodule BeamWeaver.Graph.Execution.Runner do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.Execution.Resume, as: RunResume
  alias BeamWeaver.Graph.Execution.Run
  alias BeamWeaver.Graph.Execution.RunInit
  alias BeamWeaver.Graph.Execution.RunOptions
  alias BeamWeaver.Graph.Execution.StepTransition
  alias BeamWeaver.Graph.Execution.Telemetry
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Options, as: TraceOptions

  # Runs a graph to its end. Events go to the `:stream_sink` option, if any.
  @spec execute(map(), map(), keyword()) ::
          {:ok, map()}
          | {:interrupted, map()}
          | {:parent_command, Command.t()}
          | {:error, Error.t()}
  def execute(compiled, input, opts) do
    options = RunOptions.from(compiled, opts)
    parent_context = Tracing.capture_context()

    case RunResume.normalize(compiled, options.config, options.resume_fetch) do
      {:ok, resume} ->
        Tracing.attach_context(parent_context, fn ->
          {:ok, trace_run} =
            Tracing.start_run(TraceOptions.name(options.trace, compiled.name),
              kind: :graph,
              inputs: nil,
              tags: [:graph],
              metadata: trace_metadata(options),
              context_metadata: trace_metadata(options)
            )

          case RunInit.build(compiled, ChannelMerge.prepare_update(input, compiled.graph), options, resume) do
            {:ok, run} ->
              telemetry = %{graph: compiled.name, run_id: run.run_id}
              started_at = Telemetry.start(:start, telemetry)

              run
              |> run_loop()
              |> finish_result(trace_run, compiled, {started_at, telemetry})

            {:error, error} ->
              Tracing.fail_run(trace_run, error)
              {:error, error}
          end
        end)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp finish_result({:ok, state, final_config}, trace_run, compiled, {started_at, telemetry}) do
    output = ChannelLookup.public_state(compiled.graph, state)

    Tracing.finish_run(trace_run,
      outputs: nil,
      metadata: %{checkpoint_config: final_config}
    )

    Telemetry.stop(:stop, started_at, telemetry)
    {:ok, output}
  end

  defp finish_result({:interrupted, interrupt}, trace_run, _compiled, {started_at, telemetry}) do
    Tracing.finish_run(trace_run, outputs: nil)
    Telemetry.stop(:interrupt, started_at, Map.merge(interrupt, telemetry))
    {:interrupted, interrupt}
  end

  defp finish_result({:parent_command, command}, trace_run, _compiled, {started_at, telemetry}) do
    Tracing.finish_run(trace_run, outputs: nil)
    Telemetry.stop(:parent_command, started_at, Map.put(telemetry, :command, command))
    {:parent_command, command}
  end

  defp finish_result({:error, error}, trace_run, _compiled, {started_at, telemetry}) do
    Tracing.fail_run(trace_run, error)
    Telemetry.stop(:exception, started_at, Map.put(telemetry, :error, error))
    {:error, error}
  end

  defp run_loop(%Run{ready: [], replay_routes: []} = run), do: {:ok, run.state, run.config}

  defp run_loop(%Run{step: step, recursion_limit: limit}) when step >= limit do
    {:error, Error.new(:recursion_limit, "graph recursion limit reached", %{limit: limit, step: step})}
  end

  defp run_loop(run) do
    case StepTransition.advance(run) do
      {:continue, run} -> run_loop(run)
      {:halt, result} -> result
    end
  end

  defp trace_metadata(options) do
    %{run_id: options.run_id}
    |> TraceOptions.metadata(options.trace)
  end
end
