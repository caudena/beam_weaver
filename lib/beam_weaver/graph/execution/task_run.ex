defmodule BeamWeaver.Graph.Execution.TaskRun do
  @moduledoc false

  alias BeamWeaver.Graph.Runtime
  alias BeamWeaver.Graph.ServerInfo

  defstruct [
    :run,
    :spec,
    :prepared,
    :state,
    :error,
    :timeout,
    :scratchpad,
    :runtime
  ]

  @type t :: %__MODULE__{
          run: map(),
          spec: map(),
          prepared: map(),
          state: term(),
          error: term(),
          timeout: timeout(),
          scratchpad: term(),
          runtime: Runtime.t()
        }

  @spec new(map(), map()) :: t()
  def new(run, plan) do
    task_run = %__MODULE__{
      run: run,
      spec: plan.spec,
      prepared: plan.prepared,
      state: plan.node_state,
      error: Map.get(plan, :error),
      timeout: plan.timeout,
      scratchpad: plan.scratchpad
    }

    runtime = runtime_for(task_run)
    state = inject_managed(task_run.state, run.compiled.graph.managed, runtime)

    %{task_run | runtime: runtime, state: state}
  end

  defp inject_managed(state, managed, _runtime) when managed in [%{}, nil], do: state
  defp inject_managed(state, _managed, _runtime) when not is_map(state), do: state

  defp inject_managed(state, managed, runtime) do
    Enum.reduce(managed, state, fn {key, value}, acc ->
      Map.put(acc, key, value.__struct__.get(value, runtime))
    end)
  end

  defp runtime_for(%__MODULE__{} = task_run) do
    run = task_run.run
    spec = task_run.spec

    configurable = BeamWeaver.Checkpoint.configurable(run.config)

    %Runtime{
      context: run.context,
      store: run.compiled.store,
      checkpointer: run.compiled.checkpointer,
      cache: run.compiled.cache,
      model_opts: run.model_opts,
      config: run.config,
      graph_name: run.compiled.name,
      node: spec.name,
      step: run.step,
      scratchpad: task_run.scratchpad,
      run_id: run.run_id,
      task_id: task_run.prepared.id,
      namespace: namespace(run.config),
      previous_state: run.state,
      checkpoint: run.config,
      execution: %{
        graph: run.compiled.name,
        node: spec.name,
        step: run.step,
        task_id: task_run.prepared.id,
        path: task_run.prepared.path,
        checkpoint_id: Map.get(configurable, "checkpoint_id", ""),
        checkpoint_ns: Map.get(configurable, "checkpoint_ns", ""),
        thread_id: Map.get(configurable, "thread_id"),
        run_id: maybe_to_string(Map.get(run.config, "run_id", Map.get(run.config, :run_id))),
        task_supervisor: run.task_supervisor,
        node_attempt: 1,
        node_first_attempt_time: System.system_time(:millisecond)
      },
      stream_sink: run.stream_sink,
      stream_writer: fn value ->
        if run.stream_sink do
          envelope =
            BeamWeaver.Stream.envelope(value,
              run_id: run.run_id,
              graph: run.compiled.name,
              node: spec.name,
              task_id: task_run.prepared.id,
              step: run.step,
              namespace: namespace(run.config)
            )

          BeamWeaver.Stream.Sink.emit(run.stream_sink, envelope)
        else
          send(run.parent_pid, {:beam_weaver_graph_custom_stream, run.run_id, value})
        end

        :ok
      end,
      stream_modes: run.stream_modes,
      collect_stream?: run.collect_stream?,
      recursion_limit: max(run.recursion_limit - run.step, 0),
      server_info: run.server_info || ServerInfo.from_configurable(configurable)
    }
  end

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)

  defp namespace(config) do
    config
    |> BeamWeaver.Checkpoint.configurable()
    |> Map.get("checkpoint_ns", "")
    |> case do
      "" -> []
      value when is_binary(value) -> String.split(value, ":", trim: true)
      value when is_list(value) -> value
      value -> [value]
    end
  end
end
