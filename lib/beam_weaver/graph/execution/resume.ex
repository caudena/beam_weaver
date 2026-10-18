defmodule BeamWeaver.Graph.Execution.Resume do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Resume, as: GraphResume

  @spec normalize(map(), map(), :error | {:ok, term()}) :: {:ok, term()} | {:error, Error.t()}
  def normalize(_compiled, _config, :error), do: {:ok, nil}

  def normalize(compiled, config, {:ok, %GraphResume{} = resume}),
    do: {:ok, compiled |> Replay.pending_interrupt_records(config) |> scalar_resume_with_consumed(resume)}

  def normalize(compiled, config, {:ok, resume}) do
    pending = Replay.pending_interrupt_records(compiled, config)
    map? = is_map(resume) and not is_struct(resume)

    # An empty map answers none of the pauses, which keep the answers they
    # already used.
    cond do
      map? and pending == [] ->
        {:ok, resume}

      map? and (map_size(resume) == 0 or resume_map_targets_pending?(resume, pending)) ->
        {:ok, resume_map_to_task_values(resume, pending)}

      length(pending) > 1 ->
        {:error, Error.new(:invalid_resume, "multiple pending interrupts require a resume map keyed by interrupt id")}

      true ->
        {:ok, scalar_resume_with_consumed(pending, resume)}
    end
  end

  # Pins a resume value that every task would receive to the given tasks.
  # Values already keyed by task id are left as they are.
  @spec for_tasks(term(), [String.t()]) :: term()
  def for_tasks(nil, _task_ids), do: nil
  def for_tasks(resume, _task_ids) when is_map(resume) and not is_struct(resume), do: resume
  def for_tasks(resume, task_ids), do: Map.new(task_ids, &{&1, values_for_task(resume, &1)})

  @spec values_for_task(term(), String.t()) :: list()
  def values_for_task(nil, _task_id), do: []
  def values_for_task(%GraphResume{} = resume, _task_id), do: [resume]
  def values_for_task(values, _task_id) when is_list(values), do: values

  def values_for_task(resume, task_id) when is_map(resume) and not is_struct(resume) do
    (Map.get(resume, task_id) || Map.get(resume, to_string(task_id)) || [])
    |> List.wrap()
  end

  def values_for_task(resume, _task_id), do: [resume]

  defp scalar_resume_with_consumed([pending], resume) do
    %{pending.task_id => interrupt_resumes(pending) ++ resume_values(resume)}
  end

  defp scalar_resume_with_consumed(_pending, resume), do: resume

  defp resume_values(%GraphResume{} = resume), do: [resume]
  defp resume_values(values) when is_list(values), do: values
  defp resume_values(value), do: [value]

  defp resume_map_targets_pending?(resume, pending_interrupts) do
    pending_keys =
      pending_interrupts
      |> Enum.flat_map(&[to_string(&1.id), to_string(&1.task_id)])
      |> MapSet.new()

    Enum.any?(resume, fn {key, _value} -> MapSet.member?(pending_keys, to_string(key)) end)
  end

  # Every paused task gets the answers it already used, so it doesn't ask its
  # earlier questions again, whether or not the map answers its pause. A
  # subgraph task gets the answers to the subgraph's own pauses as one map,
  # keyed by their ids, which it hands on to the subgraph.
  defp resume_map_to_task_values(resume, pending_interrupts) do
    by_interrupt_id = Map.new(pending_interrupts, &{to_string(&1.id), {&1.task_id, subgraph_interrupt_id(&1)}})
    by_task_id = Map.new(pending_interrupts, &{to_string(&1.task_id), {&1.task_id, nil}})
    used = Map.new(pending_interrupts, &{&1.task_id, interrupt_resumes(&1)})

    {task_values, subgraph_answers} =
      Enum.reduce(resume, {used, %{}}, fn {key, value}, {task_values, subgraph_answers} ->
        key = to_string(key)

        case Map.get(by_interrupt_id, key) || Map.get(by_task_id, key) do
          nil ->
            {task_values, subgraph_answers}

          {task_id, nil} ->
            {Map.update!(task_values, task_id, &(&1 ++ List.wrap(value))), subgraph_answers}

          {task_id, id} ->
            {task_values, Map.update(subgraph_answers, task_id, %{id => value}, &Map.put(&1, id, value))}
        end
      end)

    Enum.reduce(subgraph_answers, task_values, fn {task_id, answers}, task_values ->
      Map.update!(task_values, task_id, &(&1 ++ [answers]))
    end)
  end

  defp subgraph_interrupt_id(%{subgraph?: true, id: id}), do: id
  defp subgraph_interrupt_id(_interrupt), do: nil

  defp interrupt_resumes(%{resumes: resumes}) when is_list(resumes), do: resumes
  defp interrupt_resumes(_interrupt), do: []
end
