defmodule BeamWeaver.Graph.Execution.TaskWrite do
  @moduledoc """
  Write emitted by a graph execution task before it is committed to checkpoint storage.
  """

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
