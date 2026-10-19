defmodule BeamWeaver.Graph.Execution.TaskPlanner do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.Execution.Resume
  alias BeamWeaver.Graph.Execution.Scratchpad
  alias BeamWeaver.Graph.Execution.Task, as: ExecutionTask
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.NodeSpec

  # What a task needs to run. A task that can't run fails with the reason:
  # a `Send` whose update doesn't merge into the state, or whose `timeout` is
  # invalid, or a route to a node the graph doesn't have.
  @spec prepare(map(), TaskRequest.t()) :: {:ok, map()} | {:error, Error.t(), ExecutionTask.t()}
  def prepare(%{compiled: compiled} = run, ready_entry) do
    node_name = TaskRequest.name(ready_entry)

    prepared =
      Execution.prepare_task(
        compiled.name,
        run.config,
        run.step,
        node_name,
        nil,
        TaskRequest.raw_path(ready_entry),
        run.task_trigger_versions,
        TaskRequest.kind(ready_entry)
      )

    with {:ok, spec} <- Map.fetch(compiled.graph.nodes, node_name),
         {:ok, timeout} <- task_timeout(ready_entry, spec),
         {:ok, node_state} <- ChannelMerge.ready_state(ready_entry, run.state, compiled.graph) do
      {:ok,
       %{
         spec: spec,
         prepared: %{prepared | input: node_state},
         node_state: node_state,
         scratchpad:
           Scratchpad.new(
             task_id: prepared.id,
             node: prepared.node,
             step: prepared.step,
             resume_values: Resume.values_for_task(run.resume, prepared.id)
           ),
         first_state: first_state(run, ready_entry),
         error: ready_entry.error,
         timeout: timeout,
         started_at: System.monotonic_time(:millisecond)
       }}
    else
      :error -> {:error, Error.new(:invalid_graph, "graph references a missing node", %{node: node_name}), prepared}
      {:error, %Error{} = error} -> {:error, error, prepared}
    end
  end

  # A `Send`'s own `timeout` takes the forms that a node's `timeout:` takes.
  defp task_timeout(ready_entry, spec) do
    case ready_entry.timeout do
      nil ->
        {:ok, spec.timeout || :infinity}

      timeout ->
        with {:ok, timeout, _policy} <- NodeSpec.normalize_timeout(timeout),
             do: {:ok, timeout || :infinity}
    end
  end

  # In a step that a run continues, the state the task had when the step
  # first ran; nil otherwise. A `Send` whose update didn't merge into that
  # state failed then, so its task never ran.
  defp first_state(%{continued_from: nil}, _ready_entry), do: nil

  defp first_state(%{continued_from: state, compiled: compiled}, ready_entry) do
    case ChannelMerge.ready_state(ready_entry, state, compiled.graph) do
      {:ok, state} -> state
      {:error, %Error{}} -> nil
    end
  end
end
