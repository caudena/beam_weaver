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
| `HITL.decision(:edit, edited_action: %{name: ..., args: ...})` | The call the person changed runs instead of the model's, and may name another tool. |
| `HITL.decision(:reject, message: "...")` | The tool doesn't run. The model gets a failed tool result that says the user rejected the call, for the reason in `message`, and can tell the customer or try something else. |
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

An edit changes the call before the tool runs. Edited arguments must match
the tool's input schema; an edit that doesn't is refused, and the review
stays pending:

```elixir
opts = pause_ticket.("ticket-43")
typo = HITL.decision(:edit, edited_action: %{name: "issue_refund", args: %{"order_id" => "A-1001", "amount" => "20"}})

MyApp.SupportAgent.resume_review([typo], opts)
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_human_decision}}
```

Answer the same review again with a valid edit:

```elixir
edit = HITL.decision(:edit, edited_action: %{name: "issue_refund", args: %{"order_id" => "A-1001", "amount" => 20}})

result = MyApp.SupportAgent.resume_review([edit], opts) |> tool_result.()
String.ends_with?(result, "Tool response:\nRefunded $20 for order A-1001.")
#=> true
```

The model's message keeps the call it made, so the result starts with a note
that a reviewer replaced it, followed by the call that ran (`Executed
instead: issue_refund with arguments {"amount":20,"order_id":"A-1001"}.`). To
word the note yourself, or leave it out with `nil`, list the middleware with
`edit_notice:`, as in
`middleware [{BeamWeaver.Agent.Middleware.HumanInTheLoop, interrupt_on: ..., edit_notice: nil}]`.

A rejection tells the model why:

```elixir
opts = pause_ticket.("ticket-44")
reject = HITL.decision(:reject, message: "Refunds over $20 need a manager. Offer store credit instead.")

MyApp.SupportAgent.resume_review([reject], opts) |> tool_result.()
#=> "User rejected the tool call for `issue_refund` with reason: Refunds over $20 need a manager. Offer store credit instead."
```

A rejection without `message` also tells the model that the tool didn't run
and not to retry the call unless the user asks for it.

Use `:respond` when a person is the real answer to the call, for example an
`ask_customer` tool that a support agent answers. Decisions can also be plain
maps, such as the JSON your page sends back:

```elixir
opts = pause_ticket.("ticket-45")
decisions = [%{"type" => "respond", "message" => "A manager refunded the order by phone."}]

MyApp.SupportAgent.resume_review(decisions, opts) |> tool_result.()
#=> "A manager refunded the order by phone."
```

## A new message cancels the review

The customer may write again before anyone has decided. A new message to a
thread that waits for a review cancels the review: each call of that turn
that hasn't run gets a failed tool result that says so, and the model answers
the new message. The result goes right after the model's call, where
providers expect it, before the new message:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001", "amount" => 25}),
      "Understood. Order A-1001 stays as it is."
    ]

  system_prompt "You are Acme's support agent."
  tools [MyApp.Tools.IssueRefund]
  interrupt_on %{"issue_refund" => true}
end

opts = pause_ticket.("ticket-49")
{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Actually, I'll keep the order."]}, opts)

for message <- result.messages, do: {message.role, BeamWeaver.Core.Message.text(message)}
#=> [
#     {:user, "Please refund $25 for order A-1001."},
#     {:assistant, ""},
#     {:tool, "Tool call issue_refund with id call_0_0 was not run: a new message came in while it waited for review."},
#     {:user, "Actually, I'll keep the order."},
#     {:assistant, "Understood. Order A-1001 stays as it is."}
#   ]
```

The cancelled review is no longer pending. A decision sent afterwards
answers whatever review is pending then; here none is, so nothing runs and
the thread stays as it is:

```elixir
{:ok, after_decision} = MyApp.SupportAgent.resume_review([HITL.decision(:approve)], opts)
after_decision.messages == result.messages
#=> true
```

A message added with `BeamWeaver.Graph.Compiled.update_state/4` while the
review waits cancels it the same way, also when a decision follows. With
[one pause per call](#one-pause-per-call), every call that still waits is
cancelled, and the calls that already ran keep their results. A
[subagent's](subagents.md#human-review) review is cancelled too: its `task`
call gets the failed result. A history you pass in yourself, with a call that
has no result, still fails with
`:invalid_chat_history`: only a review that a new message interrupts is
answered for you.

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
defmodule MyApp.ConditionalReviewAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  interrupt_on %{
    "issue_refund" => %{
      allowed_decisions: [:approve, :reject],
      when: fn call -> call.args["amount"] > 100 end,
      description: fn call, _state -> "Refund $#{call.args["amount"]} for order #{call.args["order_id"]}?" end
    }
  }
end

saver = BeamWeaver.Checkpoint.ETS.new()
{:ok, result} = MyApp.ConditionalReviewAgent.invoke(%{messages: ["Reply with the word ready."]},
  checkpointer: saver, config: %{"configurable" => %{"thread_id" => "configuration-example"}})
true = is_binary(result.messages |> List.last() |> BeamWeaver.Core.Message.text())
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
#=> ["User rejected the tool call for `issue_refund` with reason: Over the $100 limit.", "Order A-1001 shipped on Monday.", "Refunded $25 for order A-1001."]
```

## One pause per call

To review each call on its own, list the review middleware with
`interrupt_mode: :per_call` instead of declaring `interrupt_on`. Each call of
the turn then runs as a task of its own: a call that needs review pauses with
an interrupt of its own, and the others run straight away. The run pauses with
all of them in `interrupt.interrupts`:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
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

  middleware [
    {HumanInTheLoop,
     interrupt_mode: :per_call,
     interrupt_on: %{
       "issue_refund" => %{
         allowed_decisions: [:approve, :reject],
         description: fn call, _state -> "Refund $#{call.args["amount"]} for order #{call.args["order_id"]}?" end
       }
     }}
  ]
end

opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-48"}}]

{:interrupted, interrupt} =
  MyApp.SupportAgent.invoke(%{messages: ["Refund orders A-1001 and A-1002, please."]}, opts)

interrupt.interrupts |> Enum.map(& &1.value.description) |> Enum.sort()
#=> ["Refund $25 for order A-1001?", "Refund $300 for order A-1002?"]
```

Each interrupt's value is a `"tool_approval"` request with the call's
`tool_call_id`, `name`, `args` and `description`, the `allowed_decisions`,
and, when edits are allowed, the `args_schema` an edit's arguments must
match. Answer each with one decision, keyed by its interrupt id, all at once
or one at a time; a call without an answer waits:

```elixir
answers =
  Map.new(interrupt.interrupts, fn %{id: id, value: %{args: args}} ->
    if args["amount"] > 100,
      do: {id, HITL.decision(:reject, message: "Over the $100 limit.")},
      else: {id, HITL.decision(:approve)}
  end)

{:ok, result} = MyApp.SupportAgent.resume_review(answers, opts)

for %{role: :tool} = message <- result.messages, do: BeamWeaver.Core.Message.text(message)
#=> ["Order A-1001 shipped on Monday.", "Refunded $25 for order A-1001.", "User rejected the tool call for `issue_refund` with reason: Over the $100 limit."]
```

An edit keeps the tool and replaces its arguments. An answer that doesn't
fit, such as a decision the rule doesn't allow, fails the resume with
`:invalid_human_decision`, and the call waits for another answer. List the
review before `ToolRetry` and `ToolError`, so it comes first; middleware
listed before it runs again for each waiting call when the run resumes.
Because each call is a task of its own, tools marked `concurrent false` don't
wait for each other in this mode.

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

In a graph, call `BeamWeaver.Graph.interrupt/2` inside a node to pause and
hand a value to the caller. The value you pass to `resume/2` becomes the
return value of `Graph.interrupt/2`:

```elixir
defmodule MyApp.TicketTriage do
  use BeamWeaver.Graph

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
  `Graph.interrupt/2` runs twice. Make it safe to repeat, or move side
  effects after the interrupt.
- A node may pause several times. Answers are matched to calls by order, so
  call `Graph.interrupt/2` in the same order on every run.
- `Graph.interrupt/2` pauses by throwing. Don't wrap it in a `try` that
  catches everything.
- Use plain data for the payload and the answer; both are saved in the
  checkpoint.
- `Graph.interrupt/2` works in graph nodes, not inside tools. To let a person
  answer a tool call, use `interrupt_on` and a `:respond` decision.

## Check the answer

Give `Graph.interrupt/2` a `response_schema:` to say what answer the node
expects: a JSON-schema map or a `BeamWeaver.Schema` module. The interrupt
carries it as JSON schema in `response_schema`, as do the `interrupts` of
`get_state/1`, so your app can build its form from it. The answer is checked
against it before `Graph.interrupt/2` returns it, and an object answer comes
back with string keys, whatever keys the resume used:

```elixir
defmodule MyApp.ReplyDecision do
  use BeamWeaver.Schema

  field :send, :boolean
  field :reply, :string, required: false
end

defmodule MyApp.CheckedReply do
  use BeamWeaver.Graph

  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_node(:review, &review/1)
    |> Graph.add_edge(Graph.start(), :review)
    |> Graph.add_edge(:review, Graph.end_node())
  end

  def review(%{reply: reply}) do
    question = %{question: "Send this reply?", reply: reply}
    decision = Graph.interrupt(question, response_schema: MyApp.ReplyDecision)
    %{sent: if(decision["send"], do: decision["reply"] || reply)}
  end
end

opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-52"}}]

{:interrupted, interrupt} = MyApp.CheckedReply.invoke(%{reply: "We refunded order A-1003."}, opts)
interrupt.response_schema["required"]
#=> ["send"]
```

An answer that doesn't match fails the run with an `:invalid_resume` error,
whose `details.interrupt_id` names the interrupt. The node isn't retried and
its `error_handler:` doesn't run: the interrupt waits for another answer.

```elixir
MyApp.CheckedReply.resume(%{send: "yes"}, opts)
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_resume}}

{:ok, state} = MyApp.CheckedReply.resume(%{send: true}, opts)
state.sent
#=> "We refunded order A-1003."
```

## Several pauses at once

Parallel branches can pause in the same step. Then the run pauses on one of
the interrupts and lists them all in `interrupts`, as `get_state/1` does, and
a single resume value is rejected with
`{:error, %BeamWeaver.Core.Error{type: :invalid_resume}}`. Answer them with a
map from interrupt id to value. The map works for a single pause too:

```elixir
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-51"}}]
{:interrupted, interrupt} = MyApp.TicketTriage.invoke(%{order_id: "A-1002"}, opts)

answers = Map.new(interrupt.interrupts, &{&1.id, "We refunded order A-1002."})

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
thread. See [Subgraphs](subgraphs.md). A subgraph or a subagent that pauses
several times at once, in parallel nodes or with one pause per call, pauses
the parent with all of them: `interrupt.interrupts` and `get_state/1` on the
parent list every pause, and a map from interrupt id to answer resumes them,
as in [Several pauses at once](#several-pauses-at-once).

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

Before running the database examples on this page, set `DATABASE_URL` to
an empty PostgreSQL database reserved for examples, then run this setup in
the same IEx session. The verification command creates a disposable database.

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
end

{:ok, _repo} = MyApp.Repo.start_link(url: System.fetch_env!("DATABASE_URL"), pool_size: 2, log: false)

defmodule MyApp.CreateAgentTables do
  use Ecto.Migration

  def up, do: BeamWeaver.Migrations.up(adapters: [:checkpoint, :memory, :cache])
  def down, do: BeamWeaver.Migrations.down(adapters: [:cache, :memory, :checkpoint])
end

:ok = Ecto.Migrator.up(MyApp.Repo, 1, MyApp.CreateAgentTables, log: false)
```

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
history and its own pending review. A message that arrives through `ask/2`
while a review is pending cancels that review (see
[A new message cancels the review](#a-new-message-cancels-the-review)), and
the card it showed no longer applies. Record who decided what in your own
tables if you need an audit trail.

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): `interrupt_on`, `resume/3`, `resume_review/3` and `get_state/2`
- [`BeamWeaver.Agent.HITL`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.HITL.html): reviews, decisions and `to_map/1`
- [`BeamWeaver.Agent.Middleware.HumanInTheLoop`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.HumanInTheLoop.html): the middleware behind `interrupt_on`
- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): `interrupt/2` and `null_resume/0`
- [`BeamWeaver.Graph.Interrupt`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Interrupt.html): a pending interrupt
- [`BeamWeaver.Checkpoint.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.Ecto.html): durable checkpoints for production
