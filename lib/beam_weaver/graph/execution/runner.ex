defmodule BeamWeaver.Graph.Execution.Runner do
  @moduledoc """
  Caller-owned graph execution run loop.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.ChannelState
  alias BeamWeaver.Graph.Execution.Resume, as: RunResume
  alias BeamWeaver.Graph.Execution.Run
  alias BeamWeaver.Graph.Execution.RunInit
  alias BeamWeaver.Graph.Execution.RunOptions
  alias BeamWeaver.Graph.Execution.StepTransition
  alias BeamWeaver.Graph.Execution.Telemetry
  alias BeamWeaver.Tracing

  @spec execute(map(), map(), keyword()) ::
          {:ok, map(), list()}
          | {:interrupted, map(), list()}
          | {:parent_command, Command.t(), list()}
          | {:error, Error.t(), list()}
  def execute(compiled, input, opts) do
    options = RunOptions.from(compiled, opts)
    parent_context = Tracing.capture_context()

    case RunResume.normalize(compiled, options.config, options.resume_fetch) do
      {:ok, resume} ->
        Tracing.attach_context(parent_context, fn ->
          {:ok, trace_run} =
            Tracing.start_run(compiled.name,
              kind: :graph,
              inputs: input,
              tags: [:graph],
              metadata: trace_metadata(options)
            )

          case RunInit.build(compiled, input, options, resume) do
            {:ok, run} ->
              Telemetry.execute(:start, %{system_time: System.system_time()}, %{
                graph: compiled.name,
                run_id: options.run_id
              })

              run
              |> run_loop()
              |> finish_result(trace_run, compiled)

            {:error, error} ->
              {:error, error, []}
          end
        end)

      {:error, %Error{} = error} ->
        {:error, error, []}
    end
  end

  defp finish_result({:ok, state, events, final_config}, trace_run, compiled) do
    output = ChannelState.public_state(compiled.graph, state)

    Tracing.finish_run(trace_run,
      outputs: output,
      metadata: %{checkpoint_config: final_config}
    )

    Telemetry.execute(:stop, %{system_time: System.system_time()}, %{
      graph: compiled.name,
      run_id: Map.get(trace_run.metadata, :run_id, Map.get(trace_run.metadata, "run_id"))
    })

    {:ok, output, Enum.reverse(events)}
  end

  defp finish_result({:interrupted, interrupt, events}, trace_run, _compiled) do
    Tracing.finish_run(trace_run, outputs: interrupt)
    Telemetry.execute(:interrupt, %{system_time: System.system_time()}, interrupt)
    {:interrupted, interrupt, Enum.reverse(events)}
  end

  defp finish_result({:parent_command, command, events}, trace_run, _compiled) do
    Tracing.finish_run(trace_run, outputs: command)

    Telemetry.execute(:parent_command, %{system_time: System.system_time()}, %{
      command: command
    })

    {:parent_command, command, Enum.reverse(events)}
  end

  defp finish_result({:error, error, events}, trace_run, _compiled) do
    Tracing.fail_run(trace_run, error)
    Telemetry.execute(:exception, %{system_time: System.system_time()}, %{error: error})
    {:error, error, Enum.reverse(events)}
  end

  defp run_loop(%Run{ready: []} = run), do: {:ok, run.state, run.events, run.config}

  defp run_loop(%Run{step: step, recursion_limit: limit} = run) when step >= limit do
    {:error, Error.new(:recursion_limit, "graph recursion limit reached", %{limit: limit, step: step}), run.events}
  end

  defp run_loop(run) do
    case StepTransition.advance(run) do
      {:continue, run} -> run_loop(run)
      {:halt, result} -> result
    end
  end

  defp trace_metadata(options) do
    configurable =
      case options.config do
        %{} = config -> Map.get(config, "configurable") || Map.get(config, :configurable) || %{}
        _other -> %{}
      end

    %{run_id: options.run_id}
    |> Map.merge(public_configurable_metadata(configurable))
  end

  defp public_configurable_metadata(configurable) when is_map(configurable) do
    configurable
    |> Enum.filter(fn {key, _value} -> public_configurable_key?(key) end)
    |> Map.new(fn {key, value} -> {public_configurable_key_name(key), value} end)
  end

  defp public_configurable_metadata(_configurable), do: %{}

  defp public_configurable_key?(key) do
    public_configurable_key_name(key) in [
      :thread_id,
      :lc_agent_name,
      :ls_agent_type,
      :subagent_name,
      :execution_mode,
      :structured_output_strategy,
      :subagent_phase,
      :capture_key
    ]
  end

  defp public_configurable_key_name(key) when is_atom(key), do: key

  defp public_configurable_key_name(key) when is_binary(key) do
    case key do
      "thread_id" -> :thread_id
      "lc_agent_name" -> :lc_agent_name
      "ls_agent_type" -> :ls_agent_type
      "subagent_name" -> :subagent_name
      "execution_mode" -> :execution_mode
      "structured_output_strategy" -> :structured_output_strategy
      "subagent_phase" -> :subagent_phase
      "capture_key" -> :capture_key
      _other -> key
    end
  end

  defp public_configurable_key_name(key), do: key
end
