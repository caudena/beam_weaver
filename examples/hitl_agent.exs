# Human in the loop: the agent pauses before issue_refund runs, a reviewer
# approves the call, and the agent resumes from the checkpoint.
#
#   mix run examples/hitl_agent.exs

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Agent.HITL
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.HITLAgent.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund an order in full."

  schema do
    field :order_id, :string, description: "The order id, like A-1001"
    field :reason, :string, description: "Why the customer gets a refund"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Refunded order #{order_id}: 49.90 EUR."}
end

defmodule BeamWeaver.Examples.HITLAgent do
  use BeamWeaver.Agent

  model Support.model()
  system_prompt "You are a support agent. Refund damaged orders with issue_refund; a person reviews each refund."
  tools [BeamWeaver.Examples.HITLAgent.IssueRefund]
  interrupt_on %{"issue_refund" => true}
end

defmodule BeamWeaver.Examples.HITLAgent.Reviewer do
  # Approves every paused call until the agent finishes.
  def run({:ok, state}, _opts), do: state
  def run({:error, error}, _opts), do: raise("the agent failed: #{error.message}")

  def run({:interrupted, interrupt}, opts) do
    {:ok, review} = HITL.from_interrupt(interrupt)

    for request <- review.action_requests,
        do: IO.puts("Review: #{request.name} #{inspect(request.args)} -> approve")

    decisions = Enum.map(review.action_requests, fn _request -> HITL.decision(:approve) end)

    decisions
    |> BeamWeaver.Examples.HITLAgent.resume_review(opts)
    |> run(opts)
  end
end

saver = CheckpointETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

%{messages: messages} =
  %{messages: ["Order A-1001 arrived broken. Please refund it."]}
  |> BeamWeaver.Examples.HITLAgent.invoke(opts)
  |> BeamWeaver.Examples.HITLAgent.Reviewer.run(opts)

messages |> List.last() |> Message.text() |> IO.puts()
Support.assert_tools_called!(messages, ["issue_refund"])
