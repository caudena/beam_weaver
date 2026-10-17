# Human in the loop, one call at a time: each issue_refund call pauses on its
# own while lookups run straight away. The reviewer answers the waiting
# refunds one by one, newest first, and approves only the damaged order's.
#
#   mix run examples/hitl_per_call_agent.exs

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Agent.HITL
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.HITLPerCallAgent.IssueRefund do
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

defmodule BeamWeaver.Examples.HITLPerCallAgent.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up where an order is."

  schema do
    field :order_id, :string, description: "The order id, like A-1003"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
end

defmodule BeamWeaver.Examples.HITLPerCallAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
  alias BeamWeaver.Examples.HITLPerCallAgent.{IssueRefund, LookupOrder}

  model Support.model()

  system_prompt "You are a support agent. Refund orders with issue_refund and find orders with lookup_order; " <>
                  "call every tool a request needs at once. A person reviews each refund."

  tools [IssueRefund, LookupOrder]

  middleware [
    {HumanInTheLoop,
     interrupt_mode: :per_call, interrupt_on: %{"issue_refund" => %{allowed_decisions: [:approve, :reject]}}}
  ]
end

defmodule BeamWeaver.Examples.HITLPerCallAgent.Reviewer do
  # Answers the newest waiting refund until the agent finishes; the others
  # keep waiting meanwhile.
  def run({:ok, state}, _opts), do: state
  def run({:error, error}, _opts), do: raise("the agent failed: #{error.message}")

  def run({:interrupted, interrupt}, opts) do
    %{id: id, value: approval} = List.last(interrupt.interrupts)

    decision =
      if approval.args["order_id"] == "A-1001",
        do: HITL.decision(:approve),
        else: HITL.decision(:reject, message: "Only damaged orders get a refund.")

    IO.puts(
      "Review #{approval.name} #{inspect(approval.args)}, #{length(interrupt.interrupts)} waiting -> #{decision.type}"
    )

    %{id => decision}
    |> BeamWeaver.Examples.HITLPerCallAgent.resume_review(opts)
    |> run(opts)
  end
end

saver = CheckpointETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-43"}}]

%{messages: messages} =
  %{
    messages: [
      "Please refund order A-1001, it arrived broken, and refund order A-1002 too. And where is order A-1003?"
    ]
  }
  |> BeamWeaver.Examples.HITLPerCallAgent.invoke(opts)
  |> BeamWeaver.Examples.HITLPerCallAgent.Reviewer.run(opts)

messages |> List.last() |> Message.text() |> IO.puts()
Support.assert_tools_called!(messages, ["issue_refund", "lookup_order"])
