Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

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

defmodule BeamWeaver.Examples.ToolInjectedArgs.Agent do
  use BeamWeaver.Agent

  name("tool_injected_args")
  model(Support.model())

  tools do
    tool(BeamWeaver.Examples.ToolInjectedArgs.RecordEvent)
  end
end

{:ok, %{messages: messages}} =
  BeamWeaver.Examples.ToolInjectedArgs.Agent.invoke(
    %{messages: [Message.user("Record an event named 'demo'.")]},
    context: %{workspace: "docs"}
  )

messages |> List.last() |> Message.text() |> IO.puts()
