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
  def from_update(%ExecutionTask{} = task, update) when is_map(update),
    do: Enum.map(update, fn {channel, value} -> new(task, to_string(channel), value) end)

  def from_update(%ExecutionTask{}, _update), do: []

  @spec interrupt(ExecutionTask.t(), term()) :: t()
  def interrupt(%ExecutionTask{} = task, interrupt), do: new(task, "__interrupt__", interrupt)

  # The route of a task that finished, encoded when it is saved.
  @spec route(ExecutionTask.t(), Route.t()) :: t()
  def route(%ExecutionTask{} = task, %Route{} = route), do: new(task, Route.channel(), route)

  @spec error(ExecutionTask.t(), term()) :: t()
  def error(%ExecutionTask{} = task, error), do: new(task, "__error__", error)

  defp new(task, channel, value), do: %__MODULE__{task_id: task.id, channel: channel, value: value, path: task.path}
end
