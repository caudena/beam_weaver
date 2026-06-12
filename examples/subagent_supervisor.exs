alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message

defmodule BeamWeaver.Examples.SubagentSupervisor.SpecialistModel do
  @behaviour ChatModel

  defstruct []

  def invoke(%__MODULE__{}, _messages, _opts), do: {:ok, Message.assistant("specialist summary")}
end

defmodule BeamWeaver.Examples.SubagentSupervisor.Summarizer do
  use BeamWeaver.Agent

  name("summarizer")
  description("Summarize a delegated task.")
  model(%BeamWeaver.Examples.SubagentSupervisor.SpecialistModel{})

  system_prompt("Return a short summary.")
end

defmodule BeamWeaver.Examples.SubagentSupervisor.SupervisorModel do
  @behaviour ChatModel

  defstruct []

  def invoke(%__MODULE__{}, messages, _opts) do
    if Enum.any?(messages, &match?(%Message{role: :tool}, &1)) do
      {:ok, Message.assistant("delegation complete")}
    else
      {:ok,
       Message.assistant("",
         tool_calls: [
           %{
             id: "call-task",
             name: "task",
             args: %{"description" => "Summarize the user request.", "subagent_type" => "summarizer"}
           }
         ]
       )}
    end
  end
end

defmodule BeamWeaver.Examples.SubagentSupervisor.Agent do
  use BeamWeaver.Agent

  name("supervisor")
  model(%BeamWeaver.Examples.SubagentSupervisor.SupervisorModel{})

  subagents do
    subagent(BeamWeaver.Examples.SubagentSupervisor.Summarizer, capture_output: :summary_output)
  end
end

{:ok, %{messages: messages, subagent_outputs: outputs}} =
  BeamWeaver.Examples.SubagentSupervisor.Agent.invoke(%{messages: [Message.user("delegate")]})

captured? = Map.has_key?(outputs, :summary_output) or Map.has_key?(outputs, "summary_output")
IO.puts("#{Message.text(List.last(messages))}:#{captured?}")
