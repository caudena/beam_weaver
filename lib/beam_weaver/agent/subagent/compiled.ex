defmodule BeamWeaver.Agent.Subagent.Compiled do
  @moduledoc ~S"""
  Run an existing agent definition as a child without spec-style tool inheritance.

  `agent` is a module or a value from `BeamWeaver.Agent.build/1`. Its own tools,
  middleware and review rules remain authoritative; parent `base_middleware`
  options do not rebuild it. Parent storage and recursion limits are used only
  where the child has none of its own.

  Use `capture_output` to retain the answer in parent state and
  `inherit_messages` when the child deliberately needs parent conversational
  context. These options have the same meaning as on
  `BeamWeaver.Agent.Subagent.Spec`. A compiled child is an execution definition,
  not an already-completed result. [Subagents](subagents.md#compiled-subagents)
  explains selection and lifecycle.
  """

  defstruct [
    :name,
    :description,
    :agent,
    :generate_agent,
    :tool_count,
    :recursion_limit,
    inherit_messages: false,
    capture_output: nil,
    execution_mode: :agent_loop,
    structured_output_strategy: nil
  ]

  @type t :: %__MODULE__{}
end
