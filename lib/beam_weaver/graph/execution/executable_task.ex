defmodule BeamWeaver.Graph.Execution.ExecutableTask do
  @moduledoc false

  alias BeamWeaver.Graph.Execution.Task, as: ExecutionTask

  defstruct [
    :id,
    :node,
    :path,
    :step,
    :timeout,
    :deadline,
    :task,
    :prepared
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          node: String.t(),
          path: String.t(),
          step: non_neg_integer(),
          timeout: timeout(),
          deadline: integer() | :infinity,
          task: Task.t(),
          prepared: ExecutionTask.t()
        }
end
