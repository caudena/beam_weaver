# A research lead that delegates: the lead agent splits the question, hands
# each part to a researcher subagent with web search, and writes the answer
# with citations from what the researchers return.
#
#   mix run examples/deepagents/deep_research.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeepResearch.WebSearch do
  use BeamWeaver.Tool

  name "web_search"
  description "Search the web and return the top results with their URLs and summaries."

  schema do
    field :query, :string, description: "What to search for"
  end

  # Canned results so the example is repeatable; swap in a real search API.
  @impl true
  def invoke(_tool, %{"query" => query}, _opts) do
    {:ok,
     """
     Results for "#{query}":
     1. https://example.com/gpu-joins - GPU hash joins run 5-10x faster than CPU joins on large tables.
     2. https://example.com/columnar-gpu - Columnar layouts let GPUs scan and filter data in parallel.
     3. https://example.com/pcie-limits - Copying data over PCIe is often the bottleneck for small queries.
     """}
  end
end

defmodule BeamWeaver.Examples.DeepAgents.DeepResearch.Think do
  use BeamWeaver.Tool

  name "think"
  description "Write down a short reflection on what you found and what to search next."

  schema do
    field :thought, :string, description: "The reflection"
  end

  @impl true
  def invoke(_tool, %{"thought" => _thought}, _opts), do: {:ok, "Noted."}
end

defmodule BeamWeaver.Examples.DeepAgents.DeepResearch do
  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Examples.DeepAgents.DeepResearch.Think
  alias BeamWeaver.Examples.DeepAgents.DeepResearch.WebSearch
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    researcher =
      Spec.new(
        name: "researcher",
        description: "Researches one focused question on the web and returns sourced notes.",
        system_prompt: "Search the web, reflect with think, then return short notes, each with its source URL.",
        tools: [WebSearch, Think],
        model: Support.model(),
        middleware: Support.limits()
      )

    {:ok, agent} =
      Support.create(
        name: "research-lead",
        model: Support.model(),
        subagents: [researcher],
        system_prompt: """
        You lead a research team. You cannot search the web yourself: split the question into \
        focused parts, give each part to the researcher subagent, then write a short answer that \
        cites the URLs the researchers found.
        """
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: ["How do GPUs speed up database queries, and when do they not help? Keep it short."]
      })

    IO.puts(Message.text(List.last(messages)))
    Support.assert_tools_called!(messages, ["task"])
  end
end

BeamWeaver.Examples.DeepAgents.DeepResearch.run()
