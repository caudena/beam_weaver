defmodule BeamWeaver.Graph.Execution.Halt do
  @moduledoc false

  defstruct [
    :reason,
    :payload,
    events: [],
    pending_writes: []
  ]

  @type reason :: :error | :interrupted | :parent_command

  @type t :: %__MODULE__{
          reason: reason(),
          payload: term(),
          events: list(),
          pending_writes: list()
        }
end
