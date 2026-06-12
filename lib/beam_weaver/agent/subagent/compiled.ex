defmodule BeamWeaver.Agent.Subagent.Compiled do
  @moduledoc "Compiled synchronous subagent."

  defstruct [
    :name,
    :description,
    :agent,
    :generate_agent,
    :tool_count,
    inherit_messages: false,
    capture_output: nil,
    execution_mode: :agent_loop,
    structured_output_strategy: nil
  ]
end
