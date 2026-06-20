Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Agent.Middleware.ModelRetry
alias BeamWeaver.Agent.Middleware.TodoList
alias BeamWeaver.Agent.Middleware.ToolCallNormalization
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support
alias BeamWeaver.Filesystem.State

defmodule BeamWeaver.Examples.DeepAgentComposition.Helper do
  use BeamWeaver.Agent

  name("helper")
  description("Handle isolated helper work.")
  model(Support.model())
  system_prompt("Return the helper result in one sentence.")
end

defmodule BeamWeaver.Examples.DeepAgentComposition.Agent do
  use BeamWeaver.Agent

  name("composed_deep_agent")
  description("A deep agent built from normal BeamWeaver capabilities.")
  model(Support.model())
  filesystem(State.new())
  compact_conversation(true)

  subagents do
    subagent(BeamWeaver.Examples.DeepAgentComposition.Helper, capture_output: :helper_output)
  end

  middleware do
    use TodoList
    use ToolCallNormalization
    use ModelRetry, max_attempts: 2, retry_on: :transient
  end

  system_prompt(
    "Plan with write_todos, delegate isolated work to the helper, and use composed capabilities when useful."
  )
end

{:ok, %{messages: messages}} =
  BeamWeaver.Examples.DeepAgentComposition.Agent.invoke(%{
    messages: [Message.user("Show how you compose planning and a helper subagent for a simple task.")]
  })

messages |> List.last() |> Message.text() |> IO.puts()
