defmodule BeamWeaver.Graph.Execution.CommandRouter do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.Namespace
  alias BeamWeaver.Graph.Execution.Scheduler
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.Send

  @spec command_opts(Command.t(), keyword()) :: keyword()
  def command_opts(%Command{} = command, opts) do
    opts
    |> Keyword.put(:continue_from_checkpoint?, true)
    |> maybe_put_command_resume(command.resume)
    |> maybe_put_command_goto(command.goto)
  end

  @spec command_update(Command.t()) :: map()
  def command_update(%Command{update: update}), do: normalize_update(update)

  @spec normalize_update(term()) :: map()
  def normalize_update(nil), do: %{}
  def normalize_update(%{__struct__: _module} = update), do: Map.from_struct(update)
  def normalize_update(update) when is_map(update), do: update
  def normalize_update(_update), do: %{}

  @spec parent_command_error(Command.t()) :: {:error, Error.t()}
  def parent_command_error(%Command{} = command) do
    {:error,
     Error.new(:parent_command, "parent command reached a top-level graph", %{
       update: command.update,
       goto: command.goto
     })}
  end

  @spec normalize_node_result(term()) :: map()
  def normalize_node_result(%Command{} = command) do
    {sends, next} = command_goto(command.goto)
    update = normalize_update(command.update)
    %{update: update, updates: if(update == %{}, do: [], else: [update]), sends: sends, next: next}
  end

  def normalize_node_result(%Send{} = send),
    do: %{update: %{}, updates: [], sends: [send], next: []}

  def normalize_node_result(list) when is_list(list) do
    cond do
      Enum.all?(list, &match?(%Send{}, &1)) ->
        %{update: %{}, updates: [], sends: list, next: []}

      mixed_graph_results?(list) ->
        normalize_mixed_results(list)

      true ->
        update = %{messages: list}
        %{update: update, updates: [update], sends: [], next: []}
    end
  end

  def normalize_node_result(map) when is_map(map),
    do: %{update: map, updates: [map], sends: [], next: []}

  def normalize_node_result(nil), do: %{update: %{}, updates: [], sends: [], next: []}

  def normalize_node_result(value) do
    update = %{value: value}
    %{update: update, updates: [update], sends: [], next: []}
  end

  defp command_goto(nil), do: {[], []}
  defp command_goto(%Send{} = send), do: {[send], []}

  defp command_goto(gotos) when is_list(gotos) do
    {sends, next} =
      Enum.reduce(gotos, {[], []}, fn
        %Send{} = send, {sends, next} -> {[send | sends], next}
        nil, acc -> acc
        node, {sends, next} -> {sends, [node | next]}
      end)

    {Enum.reverse(sends), Enum.reverse(next)}
  end

  defp command_goto(node), do: {[], [node]}

  @spec add_command_goto_tasks(list(), term()) :: list()
  def add_command_goto_tasks(ready, nil), do: ready

  def add_command_goto_tasks(ready, goto) do
    {sends, next} = command_goto(goto)

    command_ready =
      Enum.map(next, &TaskRequest.pull/1) ++
        Enum.map(sends, &TaskRequest.send(&1.node, &1.update || %{}, [Scheduler.tasks_channel()]))

    Scheduler.add_tasks(ready, command_ready)
  end

  defp mixed_graph_results?(list),
    do: Enum.any?(list, &graph_result?/1) and Enum.all?(list, &(is_nil(&1) or graph_result?(&1)))

  defp graph_result?(%Command{}), do: true
  defp graph_result?(%Send{}), do: true
  defp graph_result?(value), do: is_map(value) and not is_struct(value)

  defp normalize_mixed_results(list) do
    Enum.reduce(list, %{update: %{}, updates: [], sends: [], next: []}, fn
      nil, acc ->
        acc

      %Command{} = command, acc ->
        normalized = normalize_node_result(command)
        merge_normalized(acc, normalized)

      %Send{} = send, acc ->
        %{acc | sends: acc.sends ++ [send]}

      update, acc when is_map(update) and not is_struct(update) ->
        merge_normalized(acc, %{update: update, updates: [update], sends: [], next: []})
    end)
  end

  defp merge_normalized(left, right) do
    %{
      update: Map.merge(left.update, right.update),
      updates: left.updates ++ right.updates,
      sends: left.sends ++ right.sends,
      next: left.next ++ right.next
    }
  end

  @spec scope(Command.t(), map()) :: {:current, Command.t()} | {:parent, Command.t()}
  def scope(%Command{graph: graph} = command, _run)
      when graph in [nil, "", false] do
    {:current, %{command | graph: nil}}
  end

  def scope(%Command{graph: graph} = command, _run)
      when graph in [:parent, "parent", "__parent__"] do
    {:parent, command}
  end

  def scope(%Command{} = command, run) do
    if command_target?(command.graph, current_graph_identifiers(run)) do
      {:current, %{command | graph: nil}}
    else
      {:parent, command}
    end
  end

  @spec targets_task?(Command.t(), map(), map()) :: boolean()
  def targets_task?(%Command{graph: graph}, _run, _entry)
      when graph in [nil, "", false, :parent, "parent", "__parent__"],
      do: false

  def targets_task?(%Command{graph: graph}, run, entry) do
    command_target?(graph, current_graph_identifiers(run) ++ task_graph_identifiers(run, entry))
  end

  defp maybe_put_command_resume(opts, nil), do: opts
  defp maybe_put_command_resume(opts, resume), do: Keyword.put(opts, :resume, resume)

  defp maybe_put_command_goto(opts, nil), do: opts
  defp maybe_put_command_goto(opts, goto), do: Keyword.put(opts, :command_goto, goto)

  @spec command_target?(term(), [term()]) :: boolean()
  def command_target?(target, identifiers) do
    target = to_string(target)
    target in Enum.reject(identifiers, &(&1 in [nil, ""]))
  end

  defp current_graph_identifiers(run) do
    namespace =
      run.config
      |> Checkpoint.configurable()
      |> Map.get("checkpoint_ns", "")

    [run.compiled.name, namespace, Namespace.recast(namespace)]
  end

  defp task_graph_identifiers(run, entry) do
    namespace =
      run.config
      |> Checkpoint.configurable()
      |> Map.get("checkpoint_ns", "")

    task_namespace =
      namespace
      |> Namespace.child(entry.node, entry.id)
      |> Namespace.serialize()

    [entry.node, task_namespace, Namespace.recast(task_namespace)]
  end
end
