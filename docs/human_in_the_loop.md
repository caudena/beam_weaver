# Human-in-the-Loop

Pause an agent before it runs a sensitive tool, such as issuing a refund, and
let a person approve, edit or reject the call. Graph nodes can pause the same
way to ask a person for anything, and every paused run continues where it
stopped, even days later.

## Approve a tool call

List the tools that need approval with `interrupt_on`, and give the agent a
checkpointer and a thread id so it can save its state while it waits:

```elixir
defmodule MyApp.Tools.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund part or all of an order to the customer's card."

  schema do
    field :order_id, :string, description: "The order id"
    field :amount, :number, description: "The amount to refund, in dollars"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id, "amount" => amount}, _opts) do
    {:ok, "Refunded $#{amount} for order #{order_id}."}
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001", "amount" => 25}),
      "Your refund for order A-1001 is on its way."
    ]

  system_prompt "You are Acme's support agent."
  tools [MyApp.Tools.IssueRefund]
  interrupt_on %{"issue_refund" => true}
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:interrupted, interrupt} =
  MyApp.SupportAgent.invoke(%{messages: ["Please refund $25 for order A-1001."]}, opts)
```

The model asked for `issue_refund`, so the agent saved its state and returned
`{:interrupted, interrupt}` instead of running the tool. Read the pending call
with `BeamWeaver.Agent.HITL.from_interrupt/1`:

```elixir
alias BeamWeaver.Agent.HITL

{:ok, review} = HITL.from_interrupt(interrupt)
[request] = review.action_requests
{request.name, request.args}
#=> {"issue_refund", %{"order_id" => "A-1001", "amount" => 25}}
```

When a person has decided, resume with the same `opts`, including any
`context:` (it isn't saved with the thread). The agent runs the tool and
carries on:

```elixir
{:ok, result} = MyApp.SupportAgent.resume_review([HITL.decision(:approve)], opts)

result.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Your refund for order A-1001 is on its way."
```

Calls to tools that aren't in `interrupt_on` run without a pause.

## The review

A review lists the pending calls in `action_requests` (tool name, arguments
and a description for the reviewer) and what the reviewer may do with each
in `review_configs`. `HITL.to_map/1` turns it into plain maps that you can
encode as JSON for a browser or an API:

```elixir
HITL.to_map(review)
#=> %{
#     action_requests: [
#       %{name: "issue_refund", args: %{"order_id" => "A-1001", "amount" => 25}, description: "Tool execution requires approval" <> _}
#     ],
#     review_configs: [
#       %{action_name: "issue_refund", allowed_decisions: ["approve", "edit", "reject", "respond"]}
#     ]
#   }
```

## Decisions

Answer each pending call with one decision:

| Decision | What happens |
|---|---|
| `HITL.decision(:approve)` | The tool runs with the proposed arguments. |
| `HITL.decision(:edit, edited_action: %{name: ..., args: ...})` | The tool runs with the arguments the person changed. |
| `HITL.decision(:reject, message: "...")` | The tool doesn't run. The model gets `message` as a failed tool result and can tell the customer or try something else. |
| `HITL.decision(:respond, message: "...")` | The tool doesn't run. `message` becomes the tool's successful result. |

Each example below starts a new ticket and lets it pause first:

```elixir
pause_ticket = fn thread_id ->
  opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => thread_id}}]
  {:interrupted, _interrupt} = MyApp.SupportAgent.invoke(%{messages: ["Please refund $25 for order A-1001."]}, opts)
  opts
end

tool_result = fn {:ok, result} ->
  result.messages |> Enum.find(&(&1.role == :tool)) |> BeamWeaver.Core.Message.text()
end
```

An edit changes the arguments before the tool runs. Edited arguments must
match the tool's input schema; an edit that doesn't is refused, and the
review stays pending:

```elixir
opts = pause_ticket.("ticket-43")
typo = HITL.decision(:edit, edited_action: %{name: "issue_refund", args: %{"order_id" => "A-1001", "amount" => "20"}})

MyApp.SupportAgent.resume_review([typo], opts)
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_human_decision}}
```

Answer the same review again with a valid edit:

```elixir
edit = HITL.decision(:edit, edited_action: %{name: "issue_refund", args: %{"order_id" => "A-1001", "amount" => 20}})

MyApp.SupportAgent.resume_review([edit], opts) |> tool_result.()
#=> "Refunded $20 for order A-1001."
```

A rejection tells the model why:

```elixir
opts = pause_ticket.("ticket-44")
reject = HITL.decision(:reject, message: "Refunds over $20 need a manager. Offer store credit instead.")

MyApp.SupportAgent.resume_review([reject], opts) |> tool_result.()
#=> "Refunds over $20 need a manager. Offer store credit instead."
```

Use `:respond` when a person is the real answer to the call, for example an
`ask_customer` tool that a support agent answers. Decisions can also be plain
maps, such as the JSON your page sends back:

```elixir
opts = pause_ticket.("ticket-45")
decisions = [%{"type" => "respond", "message" => "A manager refunded the order by phone."}]

MyApp.SupportAgent.resume_review(decisions, opts) |> tool_result.()
#=> "A manager refunded the order by phone."
```

## Stream a run that pauses

With `stream_events/2` and `live: true`, a pause arrives as a `Debug` event
whose payload holds the interrupt (see [Streaming](streaming.md)):

```elixir
alias BeamWeaver.Stream.Events

opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-46"}}]

{:ok, events} =
  MyApp.SupportAgent.stream_events(%{messages: ["Please refund $25 for order A-1001."]}, [live: true] ++ opts)

interrupt =
  Enum.find_value(events, fn
    %{event: %Events.Debug{payload: %{type: :interrupt, interrupt: interrupt}}} -> interrupt
    _event -> nil
  end)

{:ok, review} = HITL.from_interrupt(interrupt)
hd(review.action_requests).name
#=> "issue_refund"
```

Then resume with `resume_review/2` as before.

## Review rules

`interrupt_on` maps tool names to `true` (review every call, all four
decisions allowed), `false` (never review), or a map of rules. A map of rules
always turns review on:

```elixir
interrupt_on %{
  "issue_refund" => %{
    allowed_decisions: [:approve, :reject],
    when: fn call -> call.args["amount"] > 100 end,
    description: fn call, _state -> "Refund $#{call.args["amount"]} for order #{call.args["order_id"]}?" end
  }
}
```

| Key | Meaning |
|---|---|
| `allowed_decisions` | Which of `:approve`, `:edit`, `:reject` and `:respond` the reviewer may use. All four when you leave it out. |
| `when` | A function of the tool call (and optionally the state and runtime). The call pauses only when it returns `true`; here, refunds over $100. |
| `description` | A string, or a function of the call and the state, shown to the reviewer. |
| `args_schema` | A JSON schema for the arguments. It is passed along in `review_configs` for your edit form, and edits that don't match it are refused on resume, like edits that don't match the tool's own schema. |

A rule BeamWeaver can't read, such as an empty `allowed_decisions` or an
unknown decision, fails the agent's call (and `BeamWeaver.Agent.build/1`)
with an `:invalid_agent` error that says what is wrong, rather than letting
the tool run without review:

```elixir
{:error, error} = BeamWeaver.Agent.build(model: "fake:chat", interrupt_on: %{"issue_refund" => %{allowed_decisions: []}})
error.message
#=> "interrupt_on rule for \"issue_refund\" must allow at least one decision"
```

A decision that isn't allowed fails the resume with
`{:error, %BeamWeaver.Core.Error{type: :invalid_human_decision}}`, as does a
decision list of the wrong length. The review stays pending, so the next
`resume_review/2` with valid decisions continues the run. Offer only the
allowed decisions in your UI.

## Several calls at once

A model can ask for several tools in one turn. All the calls that need review
go into one pause, in the order the model made them; the others wait and run
together with the approved ones:

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_calls([
        {"lookup_order", %{"order_id" => "A-1001"}},
        {"issue_refund", %{"order_id" => "A-1001", "amount" => 25}},
        {"issue_refund", %{"order_id" => "A-1002", "amount" => 300}}
      ]),
      "I refunded order A-1001. A manager will look at order A-1002."
    ]

  tools [MyApp.Tools.LookupOrder, MyApp.Tools.IssueRefund]

  interrupt_on %{
    "issue_refund" => %{
      allowed_decisions: [:approve, :reject],
      description: fn call, _state -> "Refund $#{call.args["amount"]} for order #{call.args["order_id"]}?" end
    }
  }
end

opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-47"}}]

{:interrupted, interrupt} =
  MyApp.SupportAgent.invoke(%{messages: ["Refund orders A-1001 and A-1002, please."]}, opts)

{:ok, review} = HITL.from_interrupt(interrupt)
Enum.map(review.action_requests, & &1.description)
#=> ["Refund $25 for order A-1001?", "Refund $300 for order A-1002?"]
```

Give one decision per request, in the same order:

```elixir
decisions = [HITL.decision(:approve), HITL.decision(:reject, message: "Over the $100 limit.")]
{:ok, result} = MyApp.SupportAgent.resume_review(decisions, opts)

for %{role: :tool} = message <- result.messages, do: BeamWeaver.Core.Message.text(message)
#=> ["Over the $100 limit.", "Order A-1001 shipped on Monday.", "Refunded $25 for order A-1001."]
```

## A checkpointer is required

A paused run lives in its checkpoint, so `interrupt_on` refuses to run without
a checkpointer:

```elixir
MyApp.SupportAgent.invoke(%{messages: ["Refund orders A-1001 and A-1002, please."]})
#=> {:error, %BeamWeaver.Core.Error{type: :missing_checkpointer}}
```

Resume with the same checkpointer and `thread_id` that paused the run.
`Checkpoint.ETS` keeps runs in memory, which suits tests and development. In
production use `BeamWeaver.Checkpoint.Ecto`, so a review can wait through
restarts and deploys; `get_state/1` shows a thread's pending pauses at any
time. See [Checkpoints and Time Travel](checkpoints.md).

## Pause a graph node

In a graph, call `BeamWeaver.Graph.interrupt/1` inside a node to pause and
hand a value to the caller. The value you pass to `resume/2` becomes the
return value of `Graph.interrupt/1`:

```elixir
defmodule MyApp.TicketTriage do
  use BeamWeaver.Agent

  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_node(:draft, &draft/1)
    |> Graph.add_node(:review, &review/1)
    |> Graph.add_node(:send, &send_reply/1)
    |> Graph.add_edge(Graph.start(), :draft)
    |> Graph.add_edge(:draft, :review)
    |> Graph.add_edge(:review, :send)
    |> Graph.add_edge(:send, Graph.end_node())
  end

  def draft(%{order_id: order_id}), do: %{reply: "We refunded order #{order_id}."}

  def review(%{reply: reply}) do
    %{reply: Graph.interrupt(%{question: "Send this reply?", reply: reply})}
  end

  def send_reply(%{reply: reply}), do: %{sent: reply}
end

opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-50"}}]

{:interrupted, interrupt} = MyApp.TicketTriage.invoke(%{order_id: "A-1001"}, opts)
interrupt.value
#=> %{question: "Send this reply?", reply: "We refunded order A-1001."}
```

Here the person edits the reply before it goes out:

```elixir
{:ok, state} = MyApp.TicketTriage.resume("We refunded order A-1001. Expect it within 5 days.", opts)
state.sent
#=> "We refunded order A-1001. Expect it within 5 days."
```

Keep these rules in mind:

- On resume the node runs again from the top, so code before
  `Graph.interrupt/1` runs twice. Make it safe to repeat, or move side
  effects after the interrupt.
- A node may pause several times. Answers are matched to calls by order, so
  call `Graph.interrupt/1` in the same order on every run.
- `Graph.interrupt/1` pauses by throwing. Don't wrap it in a `try` that
  catches everything.
- Use plain data for the payload and the answer; both are saved in the
  checkpoint.
- `Graph.interrupt/1` works in graph nodes, not inside tools. To let a person
  answer a tool call, use `interrupt_on` and a `:respond` decision.

## Several pauses at once

Parallel branches can pause in the same step. Then `invoke/2` reports one of
the interrupts, `get_state/1` lists them all, and a single resume value is
rejected with `{:error, %BeamWeaver.Core.Error{type: :invalid_resume}}`.
Answer them with a map from interrupt id to value. The map works for a single
pause too:

```elixir
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-51"}}]
{:interrupted, _interrupt} = MyApp.TicketTriage.invoke(%{order_id: "A-1002"}, opts)

{:ok, snapshot} = MyApp.TicketTriage.get_state(opts)
answers = Map.new(snapshot.interrupts, &{&1.id, "We refunded order A-1002."})

{:ok, state} = MyApp.TicketTriage.resume(answers, opts)
state.sent
#=> "We refunded order A-1002."
```

In this map a `nil` value means "no answer yet", and that branch pauses
again. To answer with `nil`, use `BeamWeaver.Graph.null_resume/0`.

## Pause before or after a step

`interrupt_before` and `interrupt_after` pause a run around whole steps,
without code in a node: before every tool round, for example, so a person can
look at the calls first. An agent's steps are `:model` and `:tools`. A graph's
steps are its nodes, declared the same way in a graph module or passed to
`Graph.compile!/2`:

```elixir
defmodule MyApp.CarefulAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001", "amount" => 25}),
      "Your refund for order A-1001 is on its way."
    ]

  tools [MyApp.Tools.IssueRefund]
  interrupt_before [:tools]
end

opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-52"}}]

{:interrupted, interrupt} =
  MyApp.CarefulAgent.invoke(%{messages: ["Please refund $25 for order A-1001."]}, opts)

{interrupt.timing, interrupt.nodes}
#=> {:before, ["tools"]}
```

A breakpoint has no review to answer: `resume/2` with `nil` continues the run
past it, and the run pauses again the next time it reaches the tools:

```elixir
{:ok, result} = MyApp.CarefulAgent.resume(nil, opts)

result.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Your refund for order A-1001 is on its way."
```

To change the state before the run continues, for example to correct the
tool call, use `BeamWeaver.Graph.Compiled.update_state/4` (see
[Checkpoints and Time Travel](checkpoints.md#update-state-from-outside-a-run)).

## Subgraphs and subagents

A graph that runs as a node of another graph can pause too: the parent
returns `{:interrupted, interrupt}` and you resume the parent with the same
thread. See [Subgraphs](subgraphs.md).

Subagents pause the same way. When a subagent's tool needs review, the
parent returns `{:interrupted, interrupt}` with the subagent's review, and
`resume_review/2` on the parent resumes the subagent. A subagent uses the
parent's `interrupt_on` rules unless it has its own, and a parent whose
subagents, or their own subagents, review tools needs a checkpointer; see
[Subagents](subagents.md#human-review).

## A review flow for your app

A small module can own the whole loop. A controller or LiveView calls `ask/2`
when a message arrives, shows a `{:review, review}` result as a card with a
button per allowed decision, and calls `decide/2` with the person's choice:

```elixir
defmodule MyApp.RefundDesk do
  alias BeamWeaver.Agent.HITL
  alias BeamWeaver.Core.Message

  def ask(ticket_id, question) do
    MyApp.SupportAgent.invoke(%{messages: [question]}, opts(ticket_id)) |> present()
  end

  # `decisions` can come straight from JSON: [%{"type" => "approve"}]
  def decide(ticket_id, decisions) do
    MyApp.SupportAgent.resume_review(decisions, opts(ticket_id)) |> present()
  end

  defp present({:interrupted, interrupt}) do
    {:ok, review} = HITL.from_interrupt(interrupt)
    {:review, HITL.to_map(review)}
  end

  defp present({:ok, state}), do: {:answer, state.messages |> List.last() |> Message.text()}
  defp present({:error, error}), do: {:error, error}

  defp opts(ticket_id) do
    [
      checkpointer: BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo),
      config: %{"configurable" => %{"thread_id" => ticket_id}}
    ]
  end
end
```

Use the ticket id as the thread id, so each conversation keeps its own
history and its own pending review. Record who decided what in your own
tables if you need an audit trail.

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): `interrupt_on`, `resume/3`, `resume_review/3` and `get_state/2`
- [`BeamWeaver.Agent.HITL`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.HITL.html): reviews, decisions and `to_map/1`
- [`BeamWeaver.Agent.Middleware.HumanInTheLoop`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.HumanInTheLoop.html): the middleware behind `interrupt_on`
- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): `interrupt/1` and `null_resume/0`
- [`BeamWeaver.Graph.Interrupt`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Interrupt.html): a pending interrupt
- [`BeamWeaver.Checkpoint.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.Ecto.html): durable checkpoints for production
