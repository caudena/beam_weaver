defmodule BeamWeaver.Graph.Execution.TaskRun do
  @moduledoc false

  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.Namespace
  alias BeamWeaver.Graph.Execution.Stream
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
    :runtime,
    :started_at
  ]

  @type t :: %__MODULE__{
          run: map(),
          spec: map(),
          prepared: map(),
          state: term(),
          error: term(),
          timeout: timeout(),
          scratchpad: term(),
          runtime: Runtime.t(),
          started_at: integer() | nil
        }

  @spec new(map(), map()) :: t()
  def new(run, plan) do
    task_run = %__MODULE__{
      run: run,
      spec: plan.spec,
      prepared: plan.prepared,
      state: node_state(plan.node_state),
      error: plan.error,
      timeout: plan.timeout,
      scratchpad: plan.scratchpad
    }

    runtime = runtime_for(task_run)
    managed = run.compiled.graph.managed
    state = inject_managed(task_run.state, managed, runtime)
    scratchpad = %{task_run.scratchpad | first_state: first_state(plan, managed, runtime)}

    %{task_run | runtime: %{runtime | scratchpad: scratchpad}, scratchpad: scratchpad, state: state}
  end

  defp first_state(%{first_state: nil}, _managed, _runtime), do: nil

  defp first_state(%{first_state: state}, managed, runtime),
    do: state |> node_state() |> inject_managed(managed, runtime)

  # The graph's own bookkeeping channels are not part of what a node reads.
  defp node_state(state) when is_map(state) and not is_struct(state),
    do: ChannelLookup.drop_internal_keys(state)

  defp node_state(state), do: state

  defp inject_managed(state, managed, _runtime) when managed == %{}, do: state
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
      previous_state: node_state(run.state),
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
        run_id: to_string(run.run_id),
        task_supervisor: run.task_supervisor,
        node_attempt: 1,
        node_first_attempt_time: System.system_time(:millisecond)
      },
      stream_sink: run.stream_sink,
      stream_writer: Stream.writer(run, spec.name, task_run.prepared.id),
      stream_modes: run.stream_modes,
      recursion_limit: max(run.recursion_limit - run.step, 0),
      server_info: run.server_info || ServerInfo.from_configurable(configurable)
    }
  end

  # The same path of node names that the graph's own stream events carry.
  defp namespace(config) do
    config
    |> BeamWeaver.Checkpoint.configurable()
    |> Map.get("checkpoint_ns", "")
    |> Namespace.recast()
    |> Namespace.normalize()
  end
end
