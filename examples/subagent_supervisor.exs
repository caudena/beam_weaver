Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.SubagentSupervisor.Summarizer do
  use BeamWeaver.Agent

  name("summarizer")
  description("Summarize a delegated task in one or two sentences.")
  model(Support.model())
  system_prompt("Return a short summary.")
end

defmodule BeamWeaver.Examples.SubagentSupervisor.Agent do
  use BeamWeaver.Agent

  name("supervisor")
  description("Coordinate work and delegate summaries to the summarizer subagent.")
  model(Support.model())
  system_prompt("Delegate summarization to the summarizer subagent using the task tool.")

  subagents do
    subagent(BeamWeaver.Examples.SubagentSupervisor.Summarizer, capture_output: :summary_output)
  end
end

{:ok, %{messages: messages} = result} =
  BeamWeaver.Examples.SubagentSupervisor.Agent.invoke(%{
    messages: [Message.user("Summarize this request: plan a two-day trip to Lisbon.")]
  })

outputs = Map.get(result, :subagent_outputs, Map.get(result, "subagent_outputs", %{}))
captured? = Map.has_key?(outputs, :summary_output) or Map.has_key?(outputs, "summary_output")
IO.puts("#{Message.text(List.last(messages))}:#{captured?}")
