defmodule BeamWeaver.Graph.Execution.TaskWrite do
  @moduledoc false

  alias BeamWeaver.Graph.Execution.Route
  alias BeamWeaver.Graph.Execution.Task, as: ExecutionTask

  defstruct [:task_id, :channel, :value, :path]

  @type t :: %__MODULE__{
          task_id: String.t(),
          channel: String.t(),
          value: term(),
          path: String.t()
        }

  @spec from_update(ExecutionTask.t(), map()) :: [t()]
  def from_update(%ExecutionTask{} = task, update) when is_map(update) do
    Enum.map(update, fn {channel, value} ->
      %__MODULE__{
        task_id: task.id,
        channel: to_string(channel),
        value: value,
        path: task.path || ""
      }
    end)
  end

  def from_update(%ExecutionTask{}, _update), do: []

  @spec interrupt(ExecutionTask.t(), term()) :: t()
  def interrupt(%ExecutionTask{} = task, interrupt) do
    %__MODULE__{
      task_id: task.id,
      channel: "__interrupt__",
      value: interrupt,
      path: task.path || ""
    }
  end

  # The route of a task that finished, encoded when it is saved.
  @spec route(ExecutionTask.t(), Route.t()) :: t()
  def route(%ExecutionTask{} = task, %Route{} = route) do
    %__MODULE__{
      task_id: task.id,
      channel: Route.channel(),
      value: route,
      path: task.path || ""
    }
  end

  @spec error(ExecutionTask.t(), term()) :: t()
  def error(%ExecutionTask{} = task, error) do
    %__MODULE__{
      task_id: task.id,
      channel: "__error__",
      value: error,
      path: task.path || ""
    }
  end
end
