defmodule BeamWeaver.Graph.Execution.TaskCollector do
  @moduledoc """
  Awaiting, cancellation, failure policy, and pending-write collection for graph execution tasks.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.Collection
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.Halt
  alias BeamWeaver.Graph.Execution.StepOutcome
  alias BeamWeaver.Graph.Execution.Stream
  alias BeamWeaver.Graph.Execution.TaskAwaiter
  alias BeamWeaver.Graph.Execution.TaskResult
  alias BeamWeaver.Graph.Interrupt

  @doc false
  @spec collect_tasks([map()], map(), map()) ::
          {:ok, StepOutcome.t()} | {:halt, Halt.t()}
  def collect_tasks(tasks, run, graph) do
    tasks
    |> TaskAwaiter.await(run)
    |> collect_results(run, Collection.new(), :normal)
    |> case do
      {:ok, %Collection{} = collection} ->
        collection
        |> Collection.add_events(drain_custom_stream_events(run))
        |> Collection.to_step_outcome(run, graph)

      {:halt, %Halt{} = halt} ->
        {:halt, halt}
    end
  end

  @doc false
  @spec cancel_pending_tasks([map()]) :: :ok
  defdelegate cancel_pending_tasks(entries), to: TaskAwaiter

  @spec step_deadline(:infinity | non_neg_integer()) :: :infinity | integer()
  def step_deadline(:infinity), do: :infinity
  def step_deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  @spec run_deadline(:infinity | non_neg_integer()) :: :infinity | integer()
  def run_deadline(:infinity), do: :infinity
  def run_deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  @spec run_timeout_expired?(:infinity | integer()) :: boolean()
  def run_timeout_expired?(:infinity), do: false
  def run_timeout_expired?(deadline), do: deadline <= System.monotonic_time(:millisecond)

  @spec interrupt_for(:all | MapSet.t(), [term()], map(), atom()) :: map() | nil
  def interrupt_for(:all, ready, run, timing), do: interrupt_payload(ready, run, timing)

  def interrupt_for(nodes, ready, run, timing) do
    if Enum.any?(CheckpointIO.ready_names(ready), &MapSet.member?(nodes, &1)),
      do: interrupt_payload(ready, run, timing),
      else: nil
  end

  defp collect_results([], _run, %Collection{} = collection, :normal), do: {:ok, collection}

  defp collect_results([], _run, %Collection{} = collection, {:failed, %Error{} = error}),
    do: {:halt, Collection.halt(collection, :error, error)}

  defp collect_results(
         [],
         run,
         %Collection{} = collection,
         {:interrupted, interrupt, entry}
       ) do
    {:halt, Collection.halt(collection, :interrupted, interrupt_payload(interrupt, run, entry))}
  end

  defp collect_results(
         [{entry, {:ok, %TaskResult{status: :ok} = result}} | rest],
         run,
         collection,
         mode
       ) do
    result = %{result | events: result.events ++ drain_custom_stream_events(run)}
    collect_results(rest, run, Collection.add_result(collection, entry, result), mode)
  end

  defp collect_results(
         [{entry, {:ok, %TaskResult{status: :interrupted} = result}} | rest],
         run,
         collection,
         :normal
       ) do
    result = %{result | events: result.events ++ drain_custom_stream_events(run)}

    collect_results(
      rest,
      run,
      Collection.add_result(collection, entry, result),
      {:interrupted, result.interrupt, entry}
    )
  end

  defp collect_results(
         [{entry, {:ok, %TaskResult{status: :interrupted} = result}} | rest],
         run,
         collection,
         mode
       ) do
    result = %{result | events: result.events ++ drain_custom_stream_events(run)}
    collect_results(rest, run, Collection.add_result(collection, entry, result), mode)
  end

  defp collect_results(
         [{entry, {:ok, %TaskResult{status: :parent_command} = result}} | rest],
         run,
         collection,
         :normal
       ) do
    result = %{result | events: result.events ++ drain_custom_stream_events(run)}
    command = result.command

    if CommandRouter.targets_task?(command, run, entry) do
      command = %{command | graph: nil}
      normalized = CommandRouter.normalize_node_result(command)

      collect_results(
        rest,
        run,
        Collection.add_normalized_result(collection, entry, normalized, result.events),
        :normal
      )
    else
      {:halt,
       collection
       |> Collection.add_events(result.events)
       |> Collection.halt(:parent_command, command)}
    end
  end

  defp collect_results(
         [{_entry, {:ok, %TaskResult{status: :parent_command} = result}} | rest],
         run,
         collection,
         mode
       ) do
    result = %{result | events: result.events ++ drain_custom_stream_events(run)}
    collect_results(rest, run, Collection.add_events(collection, result.events), mode)
  end

  defp collect_results(
         [
           {entry, {:ok, %TaskResult{status: :error, error: %Error{} = error} = result}}
           | rest
         ],
         run,
         collection,
         mode
       ) do
    result = %{result | events: result.events ++ drain_custom_stream_events(run)}
    collection = Collection.add_task_error(collection, entry, error, result.events)
    handle_task_failure(error, rest, run, collection, mode)
  end

  defp collect_results(
         [{entry, {:error, %Error{} = error, events}} | rest],
         run,
         collection,
         mode
       ) do
    events = events ++ drain_custom_stream_events(run)
    collection = Collection.add_task_error(collection, entry, error, events)
    handle_task_failure(error, rest, run, collection, mode)
  end

  defp handle_task_failure(_error, _rest, _run, collection, {:failed, %Error{}} = mode) do
    {:halt, Collection.halt(collection, :error, elem(mode, 1))}
  end

  defp handle_task_failure(
         _error,
         rest,
         run,
         collection,
         {:interrupted, _interrupt, _entry} = mode
       ) do
    collect_results(rest, run, collection, mode)
  end

  defp handle_task_failure(error, rest, run, collection, :normal) do
    if hard_budget_error?(error) do
      {:halt, Collection.halt(collection, :error, error)}
    else
      collect_results(rest, run, collection, {:failed, error})
    end
  end

  defp drain_custom_stream_events(run), do: drain_custom_stream_events(run, [])

  defp drain_custom_stream_events(run, events) do
    expected_run_id = run.run_id

    receive do
      {:beam_weaver_graph_custom_stream, ^expected_run_id, value} ->
        drain_custom_stream_events(run, [Stream.custom_event(value) | events])
    after
      0 -> events
    end
  end

  defp hard_budget_error?(%Error{type: type}), do: type in [:run_timeout, :step_timeout]

  defp interrupt_payload(%Interrupt{} = interrupt, run, entry) do
    %{
      id: interrupt.id,
      value: interrupt.value,
      timing: :during,
      nodes: [entry.node],
      state: run.state,
      config: run.config,
      step: run.step,
      task_id: entry.id
    }
  end

  defp interrupt_payload(%{id: _id, value: _value} = interrupt, run, entry) do
    interrupt
    |> Map.put(:timing, Map.get(interrupt, :timing, :during))
    |> Map.put(:nodes, Map.get(interrupt, :nodes, [entry.node]))
    |> Map.put(:state, run.state)
    |> Map.put(:config, merge_interrupt_config(run.config, Map.get(interrupt, :config)))
    |> Map.put(:step, run.step)
    |> Map.put(:task_id, entry.id)
  end

  defp interrupt_payload(nodes, run, timing) do
    %{
      timing: timing,
      nodes: CheckpointIO.ready_names(nodes),
      state: run.state,
      config: run.config,
      step: run.step
    }
  end

  defp merge_interrupt_config(parent_config, nil), do: parent_config

  defp merge_interrupt_config(parent_config, child_config) do
    parent_map = get_in(parent_config, ["configurable", "checkpoint_map"]) || %{}
    child_configurable = get_in(child_config, ["configurable"]) || %{}
    child_map = Map.get(child_configurable, "checkpoint_map")

    target =
      Map.get(child_configurable, "checkpoint_target_ns") ||
        Map.get(child_configurable, "checkpoint_ns")

    if is_map(child_map) and map_size(child_map) > 0 do
      merged =
        child_map
        |> Map.merge(parent_map)
        |> maybe_put_target_checkpoint(target, child_map)

      update_in(
        parent_config,
        ["configurable", "checkpoint_map"],
        fn _existing -> merged end
      )
    else
      parent_config
    end
  end

  defp maybe_put_target_checkpoint(map, nil, _child_map), do: map

  defp maybe_put_target_checkpoint(map, target, child_map) do
    target = to_string(target)

    case Map.fetch(child_map, target) do
      {:ok, checkpoint_id} -> Map.put(map, target, checkpoint_id)
      :error -> map
    end
  end
end
