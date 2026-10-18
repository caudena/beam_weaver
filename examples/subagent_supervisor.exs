# Subagents: a supervisor agent hands work to a summarizer agent through the
# task tool. `capture_output:` also keeps the summarizer's answer in the
# result, under `subagent_outputs`.
#
#   mix run examples/subagent_supervisor.exs

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.SubagentSupervisor.Summarizer do
  use BeamWeaver.Agent

  name "summarizer"
  description "Summarizes a text in one or two sentences."
  model Support.model()
  system_prompt "Summarize the text you are given in one or two sentences."
end

defmodule BeamWeaver.Examples.SubagentSupervisor.Agent do
  use BeamWeaver.Agent

  name "supervisor"
  model Support.model()

  system_prompt """
  You triage support email. Have the summarizer subagent summarize each email, \
  then say which team should handle it: shipping, billing, or technical.
  """

  subagents do
    subagent BeamWeaver.Examples.SubagentSupervisor.Summarizer, capture_output: :summary
  end
end

email = """
Hi, I ordered a coffee grinder (order A-1001) two weeks ago. Tracking has said "in transit"
for nine days and nobody answers my emails. I need it before Saturday. Can you find it or
send a new one? - Ada
"""

{:ok, %{messages: messages} = result} =
  BeamWeaver.Examples.SubagentSupervisor.Agent.invoke(%{messages: ["Triage this email:\n\n" <> email]})

IO.puts(Support.assert_text!(List.last(messages)))
IO.inspect(result.subagent_outputs, label: "subagent_outputs")
Support.assert_tools_called!(messages, ["task"])
true = map_size(result.subagent_outputs) > 0
