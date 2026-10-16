defmodule BeamWeaver.Agent.Built do
  @moduledoc """
  An agent built at runtime with `BeamWeaver.Agent.build/1`.

  Run it with `BeamWeaver.Agent.invoke/3`, `stream_events/3`, `resume/3`,
  `resume_review/3` and `get_state/2`. A call's `:checkpointer`, `:store` and
  `:cache` replace the ones given to `build/1`. See
  [Agents](agents.md#agents-built-at-runtime).
  """

  alias BeamWeaver.Graph.Compiled

  defstruct [:spec, :compiled]

  @type t :: %__MODULE__{
          spec: struct(),
          compiled: Compiled.t()
        }
end
