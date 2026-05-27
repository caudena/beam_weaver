defmodule BeamWeaver.Graph.Execution.ExecutableTask do
  @moduledoc """
  Runtime wrapper for a prepared graph execution task running in a BEAM `Task`.
  """

  alias BeamWeaver.Graph.Execution.Task, as: ExecutionTask

  defstruct [
    :id,
    :node,
    :path,
    :step,
    :timeout,
    :started_at,
    :task,
    :prepared
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          node: String.t(),
          path: String.t(),
          step: non_neg_integer(),
          timeout: timeout(),
          started_at: integer(),
          task: Task.t(),
          prepared: ExecutionTask.t()
        }
end
