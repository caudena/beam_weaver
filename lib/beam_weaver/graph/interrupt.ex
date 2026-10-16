defmodule BeamWeaver.Graph.Interrupt do
  @moduledoc """
  A pause raised by `BeamWeaver.Graph.interrupt/1` inside a node.

  `value` is what the node handed to the caller. Resume the thread with
  `BeamWeaver.Graph.Compiled.resume/3`. See
  [Human-in-the-Loop](human_in_the_loop.md).
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
