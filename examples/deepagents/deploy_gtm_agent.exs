# A go-to-market agent with two kinds of helpers: a market-researcher
# subagent that runs in the conversation, and a pipeline builder that runs in
# the background on another server (an async subagent).
#
# The pipeline builder uses a local client that answers the way an Agent
# Protocol server would, so the example runs without one.
#
#   mix run examples/deepagents/deploy_gtm_agent.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeployGtmAgent.CompetitorAnalysis do
  use BeamWeaver.Tool

  name "competitor_analysis"
  description "Return notes on the main competitors in a market."

  schema do
    field :market, :string, description: "The market to analyze"
  end

  @impl true
  def invoke(_tool, %{"market" => market}, _opts) do
    {:ok,
     """
     Competitors in #{market}:
     - Python agent frameworks: large community, weak at long-running concurrent work.
     - Hosted agent platforms: easy start, vendor lock-in, per-seat pricing.
     - In-house tooling: flexible, expensive to maintain.
     """}
  end
end

defmodule BeamWeaver.Examples.DeepAgents.DeployGtmAgent.PipelineClient do
  # Stands in for the Agent Protocol server that runs the pipeline builder.
  @behaviour BeamWeaver.Agent.Protocol.Client

  @impl true
  def start_task(_subagent, _payload, _opts), do: {:ok, %{"thread_id" => "pipeline-7", "status" => "running"}}

  @impl true
  def check_task(_subagent, task_id, _opts), do: {:ok, %{"thread_id" => task_id, "status" => "running"}}

  @impl true
  def update_task(_subagent, task_id, _message, _opts), do: {:ok, %{"thread_id" => task_id, "status" => "running"}}

  @impl true
  def cancel_task(_subagent, task_id, _opts), do: {:ok, %{"thread_id" => task_id, "status" => "cancelled"}}
end

defmodule BeamWeaver.Examples.DeepAgents.DeployGtmAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Subagent.AsyncSpec
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Examples.DeepAgents.DeployGtmAgent.CompetitorAnalysis
  alias BeamWeaver.Examples.DeepAgents.DeployGtmAgent.PipelineClient
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    market_researcher =
      Spec.new(
        name: "market-researcher",
        description: "Analyzes competitors, segments, and positioning for a market.",
        system_prompt: "Use competitor_analysis, then return the findings as bullets with risks.",
        tools: [CompetitorAnalysis],
        model: Support.model(),
        middleware: Support.limits()
      )

    pipeline_builder =
      AsyncSpec.new(
        name: "pipeline-builder",
        description: "Builds a list of target accounts in the background; takes about an hour.",
        graph_id: "gtm-pipeline",
        url: "http://localhost:2024",
        client: PipelineClient
      )

    {:ok, agent} =
      Support.create(
        name: "gtm-agent",
        model: Support.model(),
        subagents: [market_researcher],
        async_subagents: [pipeline_builder]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: [
          "We're launching an Elixir library for building LLM agents. Ask the market researcher who we " <>
            "compete with, start the pipeline builder on a list of 20 target companies, and give me a " <>
            "three-bullet go-to-market plan."
        ]
      })

    IO.puts(Support.assert_text!(List.last(messages)))
    Support.assert_tools_called!(messages, ["task", "competitor_analysis", "start_async_task"])
  end
end

BeamWeaver.Examples.DeepAgents.DeployGtmAgent.run()
