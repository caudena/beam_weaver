alias BeamWeaver.Agent.Middleware.ModelRetry
alias BeamWeaver.Agent.Middleware.TodoList
alias BeamWeaver.Agent.Middleware.ToolCallNormalization
alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.Filesystem.State

defmodule BeamWeaver.Examples.DeepAgentComposition.HelperModel do
  @behaviour ChatModel

  defstruct []

  def invoke(%__MODULE__{}, _messages, _opts), do: {:ok, Message.assistant("helper result")}
end

defmodule BeamWeaver.Examples.DeepAgentComposition.Helper do
  use BeamWeaver.Agent

  name("helper")
  description("Handle isolated helper work.")
  model(%BeamWeaver.Examples.DeepAgentComposition.HelperModel{})

  system_prompt("Return the helper result.")
end

defmodule BeamWeaver.Examples.DeepAgentComposition.Model do
  @behaviour ChatModel

  defstruct []

  def invoke(%__MODULE__{}, messages, _opts) do
    if Enum.any?(messages, &match?(%Message{role: :tool}, &1)) do
      {:ok, Message.assistant("deep composition ready")}
    else
      {:ok,
       Message.assistant("",
         tool_calls: [
           %{
             id: "call-todos",
             name: "write_todos",
             args: %{"todos" => [%{"content" => "show composition", "status" => "completed"}]}
           }
         ]
       )}
    end
  end
end

defmodule BeamWeaver.Examples.DeepAgentComposition.Agent do
  use BeamWeaver.Agent

  name("composed_deep_agent")
  description("A deep agent built from normal BeamWeaver capabilities.")
  model(%BeamWeaver.Examples.DeepAgentComposition.Model{})
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

  system_prompt("Use composed capabilities when the task needs them.")
end

{:ok, %{messages: messages}} =
  BeamWeaver.Examples.DeepAgentComposition.Agent.invoke(%{messages: [Message.user("compose")]})

messages |> List.last() |> Message.text() |> IO.puts()
