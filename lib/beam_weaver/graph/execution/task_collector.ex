defmodule BeamWeaver.Graph.Execution.TaskCollector do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.Collection
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.Halt
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Execution.StepOutcome
  alias BeamWeaver.Graph.Execution.TaskAwaiter
  alias BeamWeaver.Graph.Execution.TaskResult
  alias BeamWeaver.Graph.Interrupt
  alias BeamWeaver.Graph.StateGraph

  @doc false
  @spec collect_tasks([map()], map(), map()) ::
          {:ok, StepOutcome.t()} | {:halt, Halt.t()}
  def collect_tasks(tasks, run, graph) do
    tasks
    |> TaskAwaiter.await(run)
    |> collect_results(run, Collection.new(), :normal)
    |> case do
      {:ok, %Collection{} = collection} -> Collection.to_step_outcome(collection, run, graph)
      {:halt, %Halt{} = halt} -> {:halt, halt}
    end
  end

  @spec deadline(:infinity | non_neg_integer()) :: :infinity | integer()
  def deadline(:infinity), do: :infinity
  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  @spec interrupt_for(:all | MapSet.t(), [term()], map(), atom()) :: map() | nil
  def interrupt_for(:all, ready, run, timing), do: interrupt_payload(ready, run, timing)

  def interrupt_for(nodes, ready, run, timing) do
    if Enum.any?(Replay.ready_names(ready), &MapSet.member?(nodes, &1)),
      do: interrupt_payload(ready, run, timing),
      else: nil
  end

  defp collect_results([], _run, %Collection{} = collection, :normal), do: {:ok, collection}

  defp collect_results([], _run, %Collection{} = collection, {:failed, %Error{} = error}),
    do: {:halt, Collection.halt(collection, :error, error)}

  # The run pauses on the step's first interrupt; `interrupts` lists every
  # task's, and every pause of a subgraph task, so each can be answered by its
  # id.
  defp collect_results([], run, %Collection{} = collection, {:interrupted, paused}) do
    [{interrupt, entry} | _rest] = paused = Enum.reverse(paused)

    payload =
      interrupt
      |> interrupt_payload(run, entry)
      |> Map.put(:interrupts, Enum.flat_map(paused, &Replay.task_interrupts(elem(&1, 0))))

    {:halt, Collection.halt(collection, :interrupted, payload)}
  end

  defp collect_results(
         [{entry, {:ok, %TaskResult{status: :ok} = result}} | rest],
         run,
         collection,
         mode
       ) do
    result = %{result | updates: result.updates ++ join_writes(run, entry)}

    collect_results(rest, run, Collection.add_result(collection, entry, result), mode)
  end

  defp collect_results(
         [{entry, {:ok, %TaskResult{status: :interrupted} = result}} | rest],
         run,
         collection,
         mode
       ) do
    mode =
      case mode do
        :normal -> {:interrupted, [{result.interrupt, entry}]}
        {:interrupted, paused} -> {:interrupted, [{result.interrupt, entry} | paused]}
        failed -> failed
      end

    collect_results(rest, run, Collection.add_result(collection, entry, result), mode)
  end

  defp collect_results(
         [{entry, {:ok, %TaskResult{status: :parent_command} = result}} | rest],
         run,
         collection,
         :normal
       ) do
    command = result.command

    if CommandRouter.targets_task?(command, run, entry) do
      command = %{command | graph: nil}
      normalized = CommandRouter.normalize_node_result(command)
      normalized = %{normalized | updates: normalized.updates ++ join_writes(run, entry)}

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
    collect_results(rest, run, Collection.add_events(collection, result.events), mode)
  end

  defp collect_results(
         [{entry, {:error, %Error{} = error, events}} | rest],
         run,
         collection,
         mode
       ) do
    collection = Collection.add_task_error(collection, entry, error, events)
    handle_task_failure(error, rest, run, collection, mode)
  end

  defp handle_task_failure(_error, _rest, _run, collection, {:failed, %Error{}} = mode) do
    {:halt, Collection.halt(collection, :error, elem(mode, 1))}
  end

  # A failed task fails the step even when another paused before it, as when
  # it fails first; the paused tasks stay pending.
  defp handle_task_failure(error, rest, run, collection, {:interrupted, _paused}),
    do: handle_task_failure(error, rest, run, collection, :normal)

  defp handle_task_failure(error, rest, run, collection, :normal) do
    if hard_budget_error?(error) do
      {:halt, Collection.halt(collection, :error, error)}
    else
      collect_results(rest, run, collection, {:failed, error})
    end
  end

  defp hard_budget_error?(%Error{type: type}), do: type in [:run_timeout, :step_timeout]

  # A finished task records its arrival at the joins it is upstream of, as its
  # own writes, so a retried step keeps it.
  defp join_writes(run, entry), do: StateGraph.join_writes(run.compiled.graph, entry.prepared.node)

  defp interrupt_payload(%Interrupt{} = interrupt, run, entry) do
    %{
      id: interrupt.id,
      value: interrupt.value,
      response_schema: interrupt.response_schema,
      timing: :during,
      nodes: [entry.node],
      state: interrupt_state(run),
      config: run.config,
      step: run.step,
      task_id: entry.id
    }
  end

  defp interrupt_payload(%{id: _id, value: _value} = interrupt, run, entry),
    do: interrupt |> Map.put_new(:timing, :during) |> Map.put_new(:nodes, [entry.node]) |> pausing(run, entry)

  # A subgraph that stopped at a breakpoint pauses its parent's task.
  defp interrupt_payload(%{timing: timing, nodes: _nodes} = interrupt, run, entry) when timing in [:before, :after],
    do: pausing(interrupt, run, entry)

  defp interrupt_payload(nodes, run, timing) do
    %{
      timing: timing,
      nodes: Replay.ready_names(nodes),
      state: interrupt_state(run),
      config: run.config,
      step: run.step
    }
  end

  # A subgraph's pause as the pause of its task in this run.
  defp pausing(interrupt, run, entry) do
    Map.merge(interrupt, %{
      state: interrupt_state(run),
      config: merge_interrupt_config(run.config, Map.get(interrupt, :config)),
      step: run.step,
      task_id: entry.id
    })
  end

  # What the caller sees of the paused run: its public state, as in `get_state/2`.
  defp interrupt_state(run), do: ChannelLookup.public_state(run.compiled.graph, run.state)

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

      put_in(parent_config, ["configurable", "checkpoint_map"], merged)
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
