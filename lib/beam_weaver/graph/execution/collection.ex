defmodule BeamWeaver.Graph.Execution.Collection do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution.ChannelState
  alias BeamWeaver.Graph.Execution.Halt
  alias BeamWeaver.Graph.Execution.StepOutcome
  alias BeamWeaver.Graph.Execution.TaskResult
  alias BeamWeaver.Graph.Execution.TaskWrite

  defstruct updates: [],
            completed_nodes: [],
            sends: [],
            next: [],
            events: [],
            pending_writes: []

  @type t :: %__MODULE__{
          updates: list(),
          completed_nodes: [String.t()],
          sends: list(),
          next: list(),
          events: list(),
          pending_writes: list()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec add_result(t(), map(), TaskResult.t()) :: t()
  def add_result(%__MODULE__{} = collection, entry, %TaskResult{status: :ok} = result) do
    add_normalized_result(
      collection,
      entry,
      %{update: result.update, updates: result.updates, sends: result.sends, next: result.next},
      result.events
    )
  end

  def add_result(
        %__MODULE__{} = collection,
        entry,
        %TaskResult{status: :interrupted} = result
      ) do
    collection
    |> add_events(result.events)
    |> add_pending_writes([TaskWrite.interrupt(entry.prepared, result.interrupt)])
  end

  def add_result(
        %__MODULE__{} = collection,
        _entry,
        %TaskResult{status: :parent_command} = result
      ) do
    add_events(collection, result.events)
  end

  def add_result(%__MODULE__{} = collection, entry, %TaskResult{status: :error} = result) do
    add_task_error(collection, entry, result.error, result.events)
  end

  @spec add_normalized_result(t(), map(), map(), list()) :: t()
  def add_normalized_result(%__MODULE__{} = collection, entry, normalized, events) do
    updates = normalized_updates(normalized)

    collection
    |> add_completed_node(entry)
    |> add_normalized(normalized, updates, events, task_pending_writes(entry, updates))
  end

  @spec add_task_error(t(), map(), Error.t(), list()) :: t()
  def add_task_error(%__MODULE__{} = collection, entry, %Error{} = error, events) do
    collection
    |> add_events(events)
    |> add_pending_writes([TaskWrite.error(entry.prepared, error)])
  end

  @spec add_events(t(), list()) :: t()
  def add_events(%__MODULE__{} = collection, events) do
    %{collection | events: collection.events ++ events}
  end

  @spec add_pending_writes(t(), list()) :: t()
  def add_pending_writes(%__MODULE__{} = collection, writes) do
    %{collection | pending_writes: collection.pending_writes ++ writes}
  end

  @spec halt(t(), Halt.reason(), term()) :: Halt.t()
  def halt(%__MODULE__{} = collection, reason, payload) do
    %Halt{
      reason: reason,
      payload: payload,
      events: collection.events,
      pending_writes: collection.pending_writes
    }
  end

  @spec to_step_outcome(t(), map(), map()) :: {:ok, StepOutcome.t()} | {:halt, Halt.t()}
  def to_step_outcome(%__MODULE__{} = collection, run, graph) do
    updates = collection.updates ++ waiting_edge_updates(collection.completed_nodes, graph)

    case ChannelState.merge_step_updates(run.state, updates, graph) do
      {:ok, step_update, next_state} ->
        {:ok,
         %StepOutcome{
           step_update: step_update,
           state: next_state,
           sends: collection.sends,
           next: collection.next,
           events: collection.events
         }}

      {:error, %Error{} = error} ->
        {:halt, halt(collection, :error, error)}
    end
  end

  defp add_normalized(collection, normalized, updates, events, task_writes) do
    %{
      collection
      | updates: collection.updates ++ updates,
        sends: collection.sends ++ normalized.sends,
        next: collection.next ++ normalized.next,
        events: collection.events ++ events,
        pending_writes: collection.pending_writes ++ task_writes
    }
  end

  defp add_completed_node(%__MODULE__{} = collection, entry) do
    node = entry.prepared.node
    %{collection | completed_nodes: Enum.uniq(collection.completed_nodes ++ [node])}
  end

  defp normalized_updates(%{updates: updates}) when is_list(updates), do: updates
  defp normalized_updates(%{update: update}) when update == %{}, do: []
  defp normalized_updates(%{update: update}) when is_map(update), do: [update]
  defp normalized_updates(_normalized), do: []

  defp task_pending_writes(entry, updates) when is_list(updates) do
    Enum.flat_map(updates, &TaskWrite.from_update(entry.prepared, &1))
  end

  defp task_pending_writes(_entry, _update), do: []

  defp waiting_edge_updates([], _graph), do: []

  defp waiting_edge_updates(completed_nodes, graph) do
    graph
    |> Map.get(:waiting_edges, [])
    |> Enum.flat_map(fn spec ->
      completed_nodes
      |> Enum.filter(&(&1 in spec.upstream))
      |> Enum.map(&%{spec.channel => &1})
    end)
  end
end
