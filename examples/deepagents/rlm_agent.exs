Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.RlmAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Agent.Subagent.Compiled
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    {:ok, agent} = create_rlm_agent(max_depth: 1)

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("Fan out two arithmetic subtasks.")]})

    IO.puts(Message.text(List.last(messages)))
  end

  def create_rlm_agent(opts) do
    depth = Keyword.get(opts, :max_depth, 1)

    subagents =
      if depth > 0 do
        {:ok, child} = create_rlm_agent(max_depth: depth - 1)

        [
          %Compiled{
            name: "general-purpose",
            description: "Recursive child agent at depth #{depth - 1}.",
            agent: child
          }
        ]
      else
        [
          Spec.new(
            name: "general-purpose",
            description: "Bottomed-out general-purpose worker.",
            model: Support.model()
          )
        ]
      end

    Support.create(
      model: Support.model(),
      subagents: subagents
    )
  end
end

BeamWeaver.Examples.DeepAgents.RlmAgent.run()
