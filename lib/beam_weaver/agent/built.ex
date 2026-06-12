defmodule BeamWeaver.Agent.Built do
  @moduledoc """
  Runtime-built BeamWeaver agent.

  This is the Elixir-native counterpart to dynamic agent factories. It stores
  the same `%BeamWeaver.Agent.Spec{}` used by the `use BeamWeaver.Agent` DSL and
  a compiled graph, so dynamic agents do not bypass the normal graph runtime.
  """

  alias BeamWeaver.Agent.Spec
  alias BeamWeaver.Graph.Compiled

  defstruct [:spec, :compiled]

  @type t :: %__MODULE__{
          spec: Spec.t(),
          compiled: Compiled.t()
        }
end
