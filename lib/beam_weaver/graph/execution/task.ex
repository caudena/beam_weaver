defmodule BeamWeaver.Graph.Execution.Task do
  @moduledoc """
  Prepared graph execution task metadata before it is started in a BEAM task.
  """

  defstruct [
    :id,
    :node,
    :path,
    :raw_path,
    :step,
    :input,
    :trigger_versions,
    kind: :pull
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          node: String.t(),
          path: String.t(),
          raw_path: term(),
          step: non_neg_integer(),
          input: term(),
          trigger_versions: map(),
          kind: :pull | :push | :send | :error_handler
        }
end
