defmodule BeamWeaver.Graph.Execution.StepOutcome do
  @moduledoc false

  defstruct [
    :step_update,
    :state,
    sends: [],
    next: [],
    events: []
  ]

  @type t :: %__MODULE__{
          step_update: map(),
          state: map(),
          sends: list(),
          next: list(),
          events: list()
        }
end
