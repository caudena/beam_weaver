defmodule BeamWeaver.Runtime.Agent.State do
  @moduledoc false

  alias BeamWeaver.Core.ID
  alias BeamWeaver.Runtime.Agent.Work

  defstruct [
    :id,
    :task_supervisor,
    :subscriber_queue_limit,
    :cancel_grace_ms,
    subscribers: %{},
    active_work: %{},
    completed_work: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          task_supervisor: Supervisor.supervisor(),
          subscriber_queue_limit: non_neg_integer(),
          cancel_grace_ms: non_neg_integer(),
          subscribers: %{pid() => reference()},
          active_work: %{Work.id() => map()},
          completed_work: %{Work.id() => map()}
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, &new_id/0),
      task_supervisor: Keyword.get(opts, :task_supervisor, BeamWeaver.Runtime.TaskSupervisor),
      subscriber_queue_limit: Keyword.get(opts, :subscriber_queue_limit, 1_000),
      cancel_grace_ms: Keyword.get(opts, :cancel_grace_ms, 100)
    }
  end

  @spec status(t()) :: map()
  def status(%__MODULE__{} = state) do
    %{
      id: state.id,
      active_count: map_size(state.active_work),
      active_work: Map.keys(state.active_work),
      completed_count: map_size(state.completed_work),
      subscriber_count: map_size(state.subscribers)
    }
  end

  defp new_id do
    ID.uuidv7()
  end
end
