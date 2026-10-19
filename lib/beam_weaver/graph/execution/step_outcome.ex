defmodule BeamWeaver.Graph.Execution.StepOutcome do
  @moduledoc false

  alias BeamWeaver.Graph.Execution.Route

  defstruct [
    :step_update,
    :state,
    routes: [],
    events: []
  ]

  @type t :: %__MODULE__{
          step_update: map(),
          state: map(),
          routes: [Route.t()],
          events: list()
        }
end
