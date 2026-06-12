defmodule BeamWeaver.Runtime.Agent.State do
  @moduledoc false

  alias BeamWeaver.Core.ID
  alias BeamWeaver.Runtime.Agent.Work

  defstruct [
    :id,
    :task_supervisor,
    subscribers: %{},
    active_work: %{},
    completed_work: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          task_supervisor: Supervisor.supervisor(),
          subscribers: %{pid() => reference()},
          active_work: %{Work.id() => map()},
          completed_work: %{Work.id() => map()}
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, &new_id/0),
      task_supervisor: Keyword.get(opts, :task_supervisor, BeamWeaver.Runtime.TaskSupervisor)
    }
  end

  @spec status(t()) :: map()
  def status(%__MODULE__{} = state) do
    %{
      id: state.id,
      active_count: map_size(state.active_work),
      active_work: Map.keys(state.active_work),
      completed_count: map_size(state.completed_work)
    }
  end

  defp new_id do
    ID.uuidv7()
  end
end
