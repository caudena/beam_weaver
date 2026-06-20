Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeepResearch do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    tools = [tavily_search_stub(), think_tool()]

    researcher =
      Spec.new(
        name: "researcher",
        description: "Searches and summarizes source material for one focused research question.",
        system_prompt: "Use search first, reflect with think_tool, then return sourced notes.",
        tools: tools,
        model: Support.model()
      )

    {:ok, agent} =
      Support.create(
        model: Support.model(),
        system_prompt: """
        You are a research lead. Save the user request, create a plan, delegate independent
        searches, and synthesize the final answer with citations.
        """,
        tools: tools,
        subagents: [researcher]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("Research GPU database acceleration.")]})

    IO.puts("deep_research: " <> Message.text(List.last(messages)))
  end

  defp tavily_search_stub do
    Tool.from_function!(
      name: "tavily_search",
      description: "Search the web and return full page text. This example uses local stub data.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      },
      handler: fn %{"query" => query}, _opts ->
        "Stub search result for #{query}: current docs emphasize multi-step research."
      end
    )
  end

  defp think_tool do
    Tool.from_function!(
      name: "think_tool",
      description: "Record a short reflection before the next search.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"thought" => %{"type" => "string"}},
        "required" => ["thought"]
      },
      handler: fn %{"thought" => thought}, _opts -> "reflection saved: #{thought}" end
    )
  end
end

BeamWeaver.Examples.DeepAgents.DeepResearch.run()
