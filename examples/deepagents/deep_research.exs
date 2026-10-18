# A research lead that delegates: the lead agent splits the question, hands
# each part to a researcher subagent and writes an answer grounded in its
# results. The search tool returns fixed teaching fixtures, not live web pages.
#
#   mix run examples/deepagents/deep_research.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeepResearch.WebSearch do
  use BeamWeaver.Tool

  name "web_search"
  description "Return fixed demonstration research snippets and their source IDs."

  schema do
    field :query, :string, description: "What to search for"
  end

  # Canned results so the example is repeatable; swap in a real search API.
  @impl true
  def invoke(_tool, %{"query" => query}, _opts) do
    {:ok,
     """
     Results for "#{query}":
     [gpu-parallelism] Teaching fixture: GPUs can process large scans, filters and hash joins in parallel.
     [gpu-transfer] Teaching fixture: copying data to the GPU can dominate small queries; limited device memory can force extra transfers.
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
  alias BeamWeaver.Examples.DeepAgents.DeepResearch.Think
  alias BeamWeaver.Examples.DeepAgents.DeepResearch.WebSearch
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    researcher =
      Spec.new(
        name: "researcher",
        description: "Answers one focused question using the fixed research snippets.",
        system_prompt:
          "Call web_search once, then think once, then return short notes citing the supplied " <>
            "[gpu-parallelism] or [gpu-transfer] IDs. The snippets are fixed teaching fixtures; repeated searches " <>
            "return the same data. Use only those snippets and do not invent sources or URLs.",
        tools: [WebSearch, Think],
        model: Support.model(),
        middleware: Support.limits()
      )

    {:ok, agent} =
      Support.create(
        name: "research-lead",
        model: Support.model(),
        subagents: [researcher, BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)],
        system_prompt: """
        You lead a demonstration research team using fixed snippets. Call task exactly twice, \
        both times with subagent_type researcher: once for GPU benefits and once for limitations. \
        Combine the two reports into a short answer citing [gpu-parallelism] and [gpu-transfer]. \
        Use only those fixture IDs; do not add external sources or URLs. Finish after those two tasks.
        """
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: ["How do GPUs speed up database queries, and when do they not help? Keep it short."]
      })

    answer = Support.assert_text!(List.last(messages))
    IO.puts(answer)
    Support.assert_tools_called!(messages, ["task", "web_search", "think"])
    tasks = for message <- messages, call <- message.tool_calls, call.name == "task", do: call
    2 = length(tasks)
    true = String.contains?(answer, "[gpu-parallelism]") and String.contains?(answer, "[gpu-transfer]")
    false = String.match?(answer, ~r{https?://})
  end
end

BeamWeaver.Examples.DeepAgents.DeepResearch.run()
