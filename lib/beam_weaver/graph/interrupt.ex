defmodule BeamWeaver.Graph.Interrupt do
  @moduledoc """
  Human-in-the-loop interrupt emitted by a graph execution task.

  The struct is intentionally small and serializable. Runtime-only details such
  as counters live in `BeamWeaver.Graph.Execution.Scratchpad`.
  """

  defstruct [:id, :value, :task_id, :node, :step, resumes: []]

  @type t :: %__MODULE__{
          id: String.t(),
          value: term(),
          task_id: String.t(),
          node: String.t(),
          step: non_neg_integer(),
          resumes: list()
        }
end
