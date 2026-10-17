defmodule BeamWeaver.Graph.Execution.Collection do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.Execution.Halt
  alias BeamWeaver.Graph.Execution.Route
  alias BeamWeaver.Graph.Execution.StepOutcome
  alias BeamWeaver.Graph.Execution.TaskResult
  alias BeamWeaver.Graph.Execution.TaskWrite

  defstruct updates: [],
            routes: [],
            events: [],
            pending_writes: []

  @type t :: %__MODULE__{
          updates: list(),
          routes: [Route.t()],
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

  # A finished task's writes and route. Its pending writes, saved only if the
  # step stops partway, include the route.
  @spec add_normalized_result(t(), map(), map(), list()) :: t()
  def add_normalized_result(%__MODULE__{} = collection, entry, normalized, events) do
    updates = normalized.updates
    route = Route.new(entry.prepared.node, normalized)

    %{
      collection
      | updates: collection.updates ++ updates,
        routes: collection.routes ++ [route],
        events: collection.events ++ events,
        pending_writes:
          collection.pending_writes ++
            task_pending_writes(entry, updates) ++ [TaskWrite.route(entry.prepared, route)]
    }
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

  defp add_pending_writes(%__MODULE__{} = collection, writes) do
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
    replayed = Execution.pending_channels(Map.get(run, :replay_pending_writes) || [])

    case ChannelMerge.apply_step_writes(run.state, collection.updates, graph, replayed) do
      {:ok, step_update, next_state} ->
        {:ok,
         %StepOutcome{
           step_update: step_update,
           state: next_state,
           routes: collection.routes,
           events: collection.events
         }}

      {:error, %Error{} = error} ->
        {:halt, halt(collection, :error, error)}
    end
  end

  defp task_pending_writes(entry, updates) when is_list(updates) do
    Enum.flat_map(updates, &TaskWrite.from_update(entry.prepared, &1))
  end
end
