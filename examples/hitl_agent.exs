Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Agent.HITL
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message
alias BeamWeaver.Core.Tool
alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.HITLAgent do
  use BeamWeaver.Agent

  name("hitl_agent")
  model(Support.model())
  system_prompt("Look up documentation with the lookup tool before answering.")

  tools do
    tool(
      Tool.from_function!(
        name: "lookup",
        description: "Look up documentation for a query.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        },
        handler: fn %{"query" => query}, _opts -> "Docs for #{query}: authentication uses bearer API keys." end
      )
    )
  end

  interrupt_on(%{"lookup" => true})
end

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "example-hitl"}}

{:interrupted, interrupt} =
  BeamWeaver.Examples.HITLAgent.invoke(
    %{messages: [Message.user("Look up the authentication docs and summarize them.")]},
    checkpointer: checkpointer,
    config: config
  )

{:ok, review} = HITL.from_interrupt(interrupt)
request = hd(review.action_requests)
IO.puts("review requested: #{request.name} #{inspect(request.args)}")

{:ok, %{messages: messages}} =
  BeamWeaver.Examples.HITLAgent.resume(
    %{decisions: [%{type: :respond, message: "Approved. The docs say authentication uses bearer API keys."}]},
    checkpointer: checkpointer,
    config: config
  )

IO.puts(Message.text(List.last(messages)))
