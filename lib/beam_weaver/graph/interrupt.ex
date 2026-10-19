defmodule BeamWeaver.Graph.Interrupt do
  @moduledoc """
  A pause raised by `BeamWeaver.Graph.interrupt/2` inside a node.

  `value` is what the node handed to the caller. `response_schema` is the
  JSON schema of the answer the node expects, when it gave one, for a client
  to build its form from. Resume the thread with
  `BeamWeaver.Graph.Compiled.resume/3`. See
  [Human-in-the-Loop](human_in_the_loop.md).
  """

  defstruct [:id, :value, :response_schema, :task_id, :node, :step, resumes: []]

  @type t :: %__MODULE__{
          id: String.t(),
          value: term(),
          response_schema: map() | nil,
          task_id: String.t(),
          node: String.t(),
          step: non_neg_integer(),
          resumes: list()
        }
end
