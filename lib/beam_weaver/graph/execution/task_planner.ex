defmodule BeamWeaver.Graph.Execution.TaskPlanner do
  @moduledoc false

  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelState
  alias BeamWeaver.Graph.Execution.Resume
  alias BeamWeaver.Graph.Execution.Scratchpad
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.TimeoutPolicy

  @spec prepare(map(), TaskRequest.t()) :: map()
  def prepare(%{compiled: compiled} = run, ready_entry) do
    node_name = TaskRequest.name(ready_entry)
    node_state = ChannelState.ready_state(ready_entry, run.state, compiled.graph)
    raw_path = TaskRequest.raw_path(ready_entry)
    spec = Map.fetch!(compiled.graph.nodes, node_name)

    prepared =
      Execution.prepare_task(
        compiled.name,
        run.config,
        run.step,
        spec.name,
        node_state,
        raw_path,
        run.task_trigger_versions,
        TaskRequest.kind(ready_entry)
      )

    %{
      spec: spec,
      prepared: prepared,
      node_state: node_state,
      scratchpad:
        Scratchpad.new(
          task_id: prepared.id,
          node: prepared.node,
          step: prepared.step,
          resume_values: Resume.values_for_task(run.resume, prepared.id)
        ),
      error: TaskRequest.error(ready_entry),
      timeout: normalize_task_timeout(TaskRequest.timeout(ready_entry) || spec.timeout),
      started_at: System.monotonic_time(:millisecond)
    }
  end

  @spec normalize_task_timeout(term()) :: non_neg_integer() | :infinity
  def normalize_task_timeout(:infinity), do: :infinity
  def normalize_task_timeout(nil), do: :infinity
  def normalize_task_timeout(%TimeoutPolicy{} = policy), do: timeout_policy_timeout(policy)

  def normalize_task_timeout(timeout) when is_list(timeout) do
    if timeout_policy_options?(timeout), do: timeout_policy_timeout(timeout), else: 5_000
  end

  def normalize_task_timeout(timeout) when is_map(timeout) do
    if timeout_policy_options?(timeout), do: timeout_policy_timeout(timeout), else: 5_000
  end

  def normalize_task_timeout(timeout) when is_float(timeout) and timeout >= 0,
    do: round(timeout * 1_000)

  def normalize_task_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout
  def normalize_task_timeout(_timeout), do: 5_000

  defp timeout_policy_timeout(policy) do
    case TimeoutPolicy.effective_timeout(policy) do
      {:ok, nil} -> :infinity
      {:ok, timeout} -> timeout
      {:error, _error} -> 5_000
    end
  end

  defp timeout_policy_options?(opts) when is_list(opts) do
    Enum.any?(opts, fn
      {key, _value} -> timeout_policy_key?(key)
      _other -> false
    end)
  end

  defp timeout_policy_options?(opts) when is_map(opts) do
    opts
    |> Map.keys()
    |> Enum.any?(&timeout_policy_key?/1)
  end

  defp timeout_policy_key?(key) when key in [:run_timeout, :idle_timeout, :refresh_on],
    do: true

  defp timeout_policy_key?(key) when key in ["run_timeout", "idle_timeout", "refresh_on"],
    do: true

  defp timeout_policy_key?(_key), do: false
end
