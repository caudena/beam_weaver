# Injected arguments: a tool receives the agent state and the run context next
# to the arguments the model sends. The model never sees or fills them, so a
# tool can trust values such as the workspace it writes to.
#
#   mix run examples/tool_injected_args.exs

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.ToolInjectedArgs.RecordEvent do
  use BeamWeaver.Tool

  name "record_event"
  description "Record an event in the team's activity log."

  injected :state, :state
  injected :context, :context

  schema do
    field :event, :string, description: "A short description of what happened"
  end

  @impl true
  def invoke(_tool, %{"event" => event} = input, _opts) do
    workspace = input.context[:workspace]
    messages = Map.get(input.state, :messages, [])
    "acme-ops" = workspace
    true = length(messages) > 0
    {:ok, "Logged #{inspect(event)} in workspace #{workspace} (conversation length: #{length(messages)})."}
  end
end

defmodule BeamWeaver.Examples.ToolInjectedArgs.Agent do
  use BeamWeaver.Agent

  model Support.model()
  system_prompt "You keep the team's activity log. Record events with record_event."
  tools [BeamWeaver.Examples.ToolInjectedArgs.RecordEvent]
end

{:ok, %{messages: messages}} =
  BeamWeaver.Examples.ToolInjectedArgs.Agent.invoke(
    %{messages: ["We just shipped release 2.4 to production. Please log it."]},
    context: %{workspace: "acme-ops"}
  )

messages |> List.last() |> Support.assert_text!() |> IO.puts()
Support.assert_tools_called!(messages, ["record_event"])
