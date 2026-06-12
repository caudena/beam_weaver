defmodule BeamWeaver.Graph.Execution.Resume do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Resume, as: GraphResume

  @spec normalize(map(), map(), :error | {:ok, term()}) :: {:ok, term()} | {:error, Error.t()}
  def normalize(_compiled, _config, :error), do: {:ok, nil}

  def normalize(compiled, config, {:ok, %GraphResume{} = resume}) do
    {:ok, scalar_resume_with_consumed(compiled, config, resume)}
  end

  def normalize(compiled, config, {:ok, resume}) when is_map(resume) do
    pending = Replay.pending_interrupt_records(compiled, config)

    cond do
      pending == [] ->
        {:ok, resume}

      map_size(resume) == 0 ->
        {:ok, %{}}

      length(pending) == 1 and not resume_map_targets_pending?(resume, pending) ->
        {:ok, scalar_resume_with_consumed(pending, resume)}

      length(pending) > 1 and not resume_map_targets_pending?(resume, pending) ->
        {:error,
         Error.new(
           :invalid_resume,
           "multiple pending interrupts require a resume map keyed by interrupt id"
         )}

      true ->
        {:ok, resume_map_to_task_values(resume, pending)}
    end
  end

  def normalize(compiled, config, {:ok, resume}) do
    pending = Replay.pending_interrupt_records(compiled, config)

    if length(pending) > 1 and not match?(%GraphResume{}, resume) do
      {:error,
       Error.new(
         :invalid_resume,
         "multiple pending interrupts require a resume map keyed by interrupt id"
       )}
    else
      {:ok, scalar_resume_with_consumed(pending, resume)}
    end
  end

  @spec values_for_task(term(), String.t()) :: list()
  def values_for_task(nil, _task_id), do: []
  def values_for_task(%GraphResume{} = resume, _task_id), do: [resume]
  def values_for_task(values, _task_id) when is_list(values), do: values

  def values_for_task(resume, task_id) when is_map(resume) do
    (Map.get(resume, task_id) || Map.get(resume, to_string(task_id)) || [])
    |> List.wrap()
  end

  def values_for_task(resume, _task_id), do: [resume]

  defp scalar_resume_with_consumed(compiled, config, resume) do
    compiled
    |> Replay.pending_interrupt_records(config)
    |> scalar_resume_with_consumed(resume)
  end

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

  defp resume_map_to_task_values(resume, pending_interrupts) do
    by_interrupt_id = Map.new(pending_interrupts, &{to_string(&1.id), &1.task_id})
    by_task_id = Map.new(pending_interrupts, &{to_string(&1.task_id), &1.task_id})
    by_interrupt_id_pending = Map.new(pending_interrupts, &{to_string(&1.id), &1})
    by_task_id_pending = Map.new(pending_interrupts, &{to_string(&1.task_id), &1})

    Enum.reduce(resume, %{}, fn {key, value}, task_values ->
      key = to_string(key)
      task_id = Map.get(by_interrupt_id, key) || Map.get(by_task_id, key)
      pending = Map.get(by_interrupt_id_pending, key) || Map.get(by_task_id_pending, key)

      if task_id do
        values = interrupt_resumes(pending) ++ List.wrap(value)
        Map.update(task_values, task_id, values, &(&1 ++ values))
      else
        task_values
      end
    end)
  end

  defp interrupt_resumes(%{resumes: resumes}) when is_list(resumes), do: resumes
  defp interrupt_resumes(_interrupt), do: []
end
