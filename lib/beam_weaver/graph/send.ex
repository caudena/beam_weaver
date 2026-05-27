defmodule BeamWeaver.Graph.Send do
  @moduledoc """
  Dynamic fan-out instruction.

  A node can return `%Send{}` values to schedule additional nodes with a state
  update applied before that node runs.
  """

  defstruct [:node, update: %{}, timeout: nil]

  @type t :: %__MODULE__{
          node: atom() | String.t(),
          update: term(),
          timeout: timeout()
        }
end
