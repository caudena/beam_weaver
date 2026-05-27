defmodule BeamWeaver.Runtime.Agent.Work do
  @moduledoc """
  Public handle for active or completed agent work.
  """

  @type id :: String.t()

  @enforce_keys [:id, :kind, :name, :trace_run_id]
  defstruct [:id, :kind, :name, :trace_run_id]

  @type t :: %__MODULE__{
          id: id(),
          kind: :model | :tool,
          name: String.t(),
          trace_run_id: BeamWeaver.Tracing.Run.id()
        }
end
