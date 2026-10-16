defmodule BeamWeaver.Agent.Subagent.Compiled do
  @moduledoc """
  A whole agent run as a subagent.

  `agent` is an agent module or an agent built with
  `BeamWeaver.Agent.build/1`; it runs with all its own declarations and
  doesn't take the parent's tools or review rules. It uses the parent's
  checkpointer and store when it has none of its own, and the parent's
  recursion limit unless `recursion_limit` is set here or declared by the
  agent module.

      %BeamWeaver.Agent.Subagent.Compiled{
        name: "order_historian",
        description: "Summarizes a customer's order history.",
        agent: MyApp.OrderHistorian
      }

  `capture_output` and `inherit_messages` work as for
  `BeamWeaver.Agent.Subagent.Spec`. See [Subagents](subagents.md).
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
