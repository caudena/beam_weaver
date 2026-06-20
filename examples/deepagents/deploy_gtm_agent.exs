Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeployGtmAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Agent.Subagent.AsyncSpec
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    market_researcher =
      Spec.new(
        name: "market-researcher",
        description: "Analyzes competitors, segments, and positioning.",
        system_prompt: "Return GTM findings as bullets with risks.",
        tools: [competitor_tool()],
        model: Support.model()
      )

    async_pipeline =
      AsyncSpec.new(
        name: "pipeline-builder",
        description: "Builds outbound account lists in the background.",
        graph_id: "gtm-pipeline",
        url: "http://localhost:2024"
      )

    {:ok, agent} =
      Support.create(
        name: "deploy-gtm-agent",
        model: Support.model(),
        tools: [competitor_tool()],
        subagents: [market_researcher],
        async_subagents: [async_pipeline]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("Plan a GTM motion for a developer tool.")]})

    IO.puts(Message.text(List.last(messages)))
  end

  defp competitor_tool do
    Tool.from_function!(
      name: "competitor_analysis",
      description: "Return competitor notes for a market.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"market" => %{"type" => "string"}},
        "required" => ["market"]
      },
      handler: fn %{"market" => market}, _opts -> "top competitors in #{market}: A, B, C" end
    )
  end
end

BeamWeaver.Examples.DeepAgents.DeployGtmAgent.run()
