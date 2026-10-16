# A deep agent assembled from parts: a to-do list for planning, files kept in
# the agent state, a writer subagent with its own tool, conversation
# compaction, model retries, and a cap on model calls.
#
#   mix run examples/deep_agent_composition.exs

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Agent.Middleware.ModelCallLimit
alias BeamWeaver.Agent.Middleware.ModelRetry
alias BeamWeaver.Agent.Middleware.TodoList
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.DeepAgentComposition.LaunchFacts do
  use BeamWeaver.Tool

  name "launch_facts"
  description "Look up the facts about the Q3 launch: date, scope, owners, and open risks."

  @impl true
  def invoke(_tool, _input, _opts) do
    {:ok,
     """
     Launch date: 20 October. Scope: offline mode and single sign-on.
     Owners: Ada (engineering), Grace (support), Linus (marketing).
     Open risks: load tests unfinished, help center articles not written, SSO bugs on older browsers.
     """}
  end
end

defmodule BeamWeaver.Examples.DeepAgentComposition.Writer do
  use BeamWeaver.Agent

  name "writer"
  description "Drafts documents about the Q3 launch. Only the writer can look up the launch facts."
  model Support.model()
  system_prompt "Look up the launch facts, then write the requested draft and return only the draft."
  tools [BeamWeaver.Examples.DeepAgentComposition.LaunchFacts]
end

defmodule BeamWeaver.Examples.DeepAgentComposition.Agent do
  use BeamWeaver.Agent

  model Support.model()
  model_opts timeout: 120_000
  filesystem BeamWeaver.Filesystem.State.new()
  compact_conversation true
  # Support.tool_log() lets the check below see tool calls that compaction
  # summarized away.
  middleware [TodoList.new(), ModelRetry.new(max_attempts: 2), ModelCallLimit.new(thread_limit: 12), Support.tool_log()]

  # Graph steps, not model calls: each model turn runs several middleware steps.
  recursion_limit 100

  subagents do
    subagent BeamWeaver.Examples.DeepAgentComposition.Writer
  end

  system_prompt """
  You are an assistant for a product team. Start every request by planning it with write_todos, \
  and keep the list up to date. You don't know the launch facts: only the writer subagent can look \
  them up, so anything you draft yourself would be guesswork. For each document, call task with \
  the writer subagent and say which document to draft, then save the draft it returns with \
  write_file.
  """
end

{:ok, %{messages: messages} = result} =
  BeamWeaver.Examples.DeepAgentComposition.Agent.invoke(
    %{
      messages: [
        "Get me ready for Monday's sync on the Q3 launch: a short agenda in /agenda.md, a three-line " <>
          "status note in /status.md, and the top three launch risks in /risks.md."
      ]
    },
    run_timeout: 240_000
  )

messages |> List.last() |> Message.text() |> IO.puts()
IO.puts("Files: #{result |> Map.get(:files, %{}) |> Map.keys() |> Enum.join(", ")}")
Support.assert_tools_called!(messages, ["write_todos", "task", "write_file"])
