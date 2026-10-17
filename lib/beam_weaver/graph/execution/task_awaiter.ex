defmodule BeamWeaver.Graph.Execution.TaskAwaiter do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution.Stream
  alias BeamWeaver.Graph.Execution.TaskResult
  alias BeamWeaver.Graph.Execution.Telemetry

  @spec await([map()], map()) :: [{map(), {:ok, term()} | {:error, Error.t(), list()}}]
  def await([], _run), do: []

  def await(entries, run) do
    timeout = wait_timeout(entries, run)
    tasks = Enum.map(entries, & &1.task)

    tasks
    |> Task.yield_many(timeout)
    |> Enum.zip(entries)
    |> Enum.map(fn {{_task, result}, entry} -> {entry, result} end)
    |> normalize_results(entries, run)
  end

  defp cancel_pending_tasks(entries) do
    Enum.each(entries, fn entry ->
      Task.shutdown(entry.task, :brutal_kill)

      Telemetry.execute(:node_cancel, %{count: 1}, %{
        node: entry.node,
        step: entry.step
      })
    end)
  end

  defp normalize_results(results, entries, run) do
    unresolved =
      results
      |> Enum.filter(fn {_entry, result} -> is_nil(result) end)
      |> Enum.map(fn {entry, _result} -> entry end)

    if unresolved == [] do
      Enum.map(results, fn {entry, result} -> {entry, normalize_task_result(entry, result)} end)
    else
      timeout_entry = timeout_entry(unresolved, run)
      timeout_source = timeout_source(timeout_entry, run)
      cancel_pending_tasks(unresolved)

      results
      |> Enum.reject(fn {entry, result} -> is_nil(result) and entry != timeout_entry end)
      |> Enum.map(fn
        {^timeout_entry, nil} -> {timeout_entry, task_timeout(timeout_source, timeout_entry, run)}
        {entry, result} -> {entry, normalize_task_result(entry, result)}
      end)
      |> restore_ready_order(entries)
    end
  end

  defp restore_ready_order(results, entries) do
    by_id = Map.new(results, fn {entry, result} -> {entry.id, {entry, result}} end)

    entries
    |> Enum.flat_map(fn entry ->
      case Map.fetch(by_id, entry.id) do
        {:ok, result} -> [result]
        :error -> []
      end
    end)
  end

  defp normalize_task_result(_entry, {:ok, {:ok, %TaskResult{} = result}}),
    do: {:ok, result}

  defp normalize_task_result(_entry, {:ok, {:error, %Error{} = error, events}}),
    do: {:error, error, events}

  defp normalize_task_result(entry, {:exit, reason}), do: task_exit(entry, reason)

  # `:infinity` sorts after every integer, so plain `min` picks the nearest
  # finite deadline when there is one.
  defp wait_timeout(entries, run) do
    now = System.monotonic_time(:millisecond)

    entries
    |> Enum.flat_map(&deadlines(&1, run))
    |> Enum.map(fn {_source, deadline} -> remaining(deadline, now) end)
    |> Enum.min(fn -> :infinity end)
  end

  defp timeout_entry(unresolved, run) do
    now = System.monotonic_time(:millisecond)

    Enum.find(unresolved, fn entry ->
      Enum.any?(deadlines(entry, run), fn {_source, deadline} -> remaining(deadline, now) == 0 end)
    end) || List.first(unresolved)
  end

  defp timeout_source(entry, run) do
    now = System.monotonic_time(:millisecond)

    entry
    |> deadlines(run)
    |> Enum.min_by(fn {_source, deadline} -> remaining(deadline, now) end)
    |> elem(0)
  end

  defp deadlines(entry, run),
    do: [node: entry.deadline, step: run.step_deadline, run: run.run_deadline]

  defp remaining(:infinity, _now), do: :infinity
  defp remaining(deadline, now), do: max(deadline - now, 0)

  defp task_timeout(source, entry, run) do
    {type, message, timeout, details} =
      case source do
        :run ->
          {:run_timeout, "graph run timed out", run.run_timeout, %{}}

        :step ->
          {:step_timeout, "graph step timed out", run.step_timeout, %{}}

        :node ->
          {:node_timeout, "node timed out", entry.timeout,
           %{node_timeout: entry.timeout, step_timeout: run.step_timeout, run_timeout: run.run_timeout}}
      end

    error = Error.new(type, message, Map.merge(%{node: entry.node, step: entry.step, timeout: timeout}, details))
    Telemetry.execute(type, %{duration: timeout}, %{node: entry.node, step: entry.step, error: error})

    {:error, error, [Stream.task_event(:timeout, entry.node, error, entry.step, entry.id, entry.path)]}
  end

  defp task_exit(entry, reason) do
    error =
      Error.new(:node_exit, "node task exited before returning", %{
        node: entry.node,
        step: entry.step,
        root_cause: reason,
        reason: inspect(reason)
      })

    Telemetry.execute(:node_exit, %{count: 1}, %{
      node: entry.node,
      step: entry.step,
      error: error
    })

    {:error, error, [Stream.task_event(:error, entry.node, error, entry.step, entry.id, entry.path)]}
  end
end
