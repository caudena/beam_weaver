# A recursive agent: its general-purpose subagent is another deep agent of
# the same kind, one level down, so subtasks can split again. `max_depth`
# bounds the recursion.
#
#   mix run examples/deepagents/rlm_agent.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.RlmAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Subagent.Compiled
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    {:ok, agent} = create_rlm_agent(max_depth: 1)

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: ["Work out 17 × 23 and 19 × 29 as two separate subtasks, then add the two results."]
      })

    IO.puts(Support.assert_text!(List.last(messages)))
    Support.assert_tools_called!(messages, ["task"])
    true = String.contains?(Message.text(List.last(messages)), "942")
  end

  def create_rlm_agent(max_depth: depth) do
    worker =
      if depth > 0 do
        {:ok, child} = create_rlm_agent(max_depth: depth - 1)
        %Compiled{name: "general-purpose", description: "A copy of this agent, #{depth - 1} levels deep.", agent: child}
      else
        Spec.new(
          name: "general-purpose",
          description: "Does one small task and returns the result.",
          model: Support.model(),
          middleware: Support.limits()
        )
      end

    Support.create(
      name: "rlm-depth-#{depth}",
      model: Support.model(),
      subagents: [worker],
      system_prompt: "Split work into independent subtasks and give each one to a general-purpose subagent."
    )
  end
end

BeamWeaver.Examples.DeepAgents.RlmAgent.run()
