alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message

defmodule BeamWeaver.Examples.ToolInjectedArgs.RecordEvent do
  use BeamWeaver.Tool

  name("record_event")
  description("Record an event with runtime state and context.")

  injected(:state, :state, type: :object)
  injected(:context, :context, type: :object)

  schema do
    field(:event, :string, required: true)
  end

  def invoke(_tool, input, _opts) do
    state = Map.get(input, :state, %{})
    context = Map.get(input, :context, %{})

    messages = Map.get(state, :messages, Map.get(state, "messages", []))

    {:ok, "recorded #{input["event"]} for #{Map.get(context, :workspace, "unknown")} with #{length(messages)} messages"}
  end
end

defmodule BeamWeaver.Examples.ToolInjectedArgs.Model do
  @behaviour ChatModel

  defstruct []

  def invoke(%__MODULE__{}, messages, _opts) do
    if Enum.any?(messages, &match?(%Message{role: :tool}, &1)) do
      {:ok, Message.assistant("event recorded")}
    else
      {:ok,
       Message.assistant("",
         tool_calls: [%{id: "call-record", name: "record_event", args: %{"event" => "demo"}}]
       )}
    end
  end
end

defmodule BeamWeaver.Examples.ToolInjectedArgs.Agent do
  use BeamWeaver.Agent

  model(%BeamWeaver.Examples.ToolInjectedArgs.Model{})

  tools do
    tool(BeamWeaver.Examples.ToolInjectedArgs.RecordEvent)
  end
end

{:ok, %{messages: messages}} =
  BeamWeaver.Examples.ToolInjectedArgs.Agent.invoke(%{messages: [Message.user("record")]},
    context: %{workspace: "docs"}
  )

messages |> List.last() |> Message.text() |> IO.puts()
