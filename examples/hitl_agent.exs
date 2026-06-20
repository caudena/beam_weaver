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

defmodule BeamWeaver.Examples.HITLAgent.Review do
  # Approve each paused tool call until the agent finishes.
  def run({:ok, state}, _opts), do: state

  def run({:error, error}, _opts), do: raise(ArgumentError, "agent error: #{inspect(error)}")

  def run({:interrupted, interrupt}, opts) do
    {:ok, review} = HITL.from_interrupt(interrupt)
    IO.puts("review requested: #{hd(review.action_requests).name}")

    decisions = Enum.map(review.action_requests, fn _request -> %{type: :approve} end)

    BeamWeaver.Examples.HITLAgent.resume(%{decisions: decisions}, opts)
    |> run(opts)
  end
end

opts = [checkpointer: CheckpointETS.new(), config: %{"configurable" => %{"thread_id" => "example-hitl"}}]

%{messages: messages} =
  BeamWeaver.Examples.HITLAgent.invoke(
    %{messages: [Message.user("Look up the authentication docs and summarize them.")]},
    opts
  )
  |> BeamWeaver.Examples.HITLAgent.Review.run(opts)

IO.puts(Message.text(List.last(messages)))
