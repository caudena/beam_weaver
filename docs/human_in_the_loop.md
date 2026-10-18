# Human Review

Pause before an action, present its actual arguments to a reviewer, and resume
with a decision. Tool review and graph interrupts share checkpoint storage,
but use different resume contracts.

| Need | API |
| --- | --- |
| Approve, edit or reject a tool call | `interrupt_on` and `resume_review/2` |
| Ask for data inside a graph node | `Graph.interrupt/2` and `resume/2` |
| Inspect a run before/after a step | `interrupt_before` / `interrupt_after`, then `resume(nil, opts)` |

Complete [Installation](installation.md). This example calls OpenAI but only
records a local refund receipt; it does not contact a payment service.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Approve a tool call

```elixir
defmodule MyApp.RecordRefund do
  use BeamWeaver.Tool

  name "record_refund"
  description "Record a sample refund. Invoke this to submit the requested action to runtime review."
  injected :context, :context

  schema do
    field :order_id, :string
    field :amount, :number
  end

  @impl true
  def invoke(_tool, %{"order_id" => order, "amount" => amount, context: context}, _opts) do
    send(context.observer, {:refund_recorded, order, amount})
    {:ok, %{order_id: order, amount: amount, status: "recorded"}}
  end
end

defmodule MyApp.ReviewedAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000

  system_prompt "Submit requested refunds with record_refund. A reviewer decides eligibility. Never retry a rejected refund."

  tools [MyApp.RecordRefund]
  interrupt_on %{"record_refund" => true}

  middleware [
    {BeamWeaver.Agent.Middleware.ToolChoice,
     choice: fn request ->
       if Enum.any?(request.messages, &(&1.role == :tool)), do: :none, else: :required
     end}
  ]

  context_schema do
    field :observer, :any, required: true
  end
end

alias BeamWeaver.Agent.HITL
saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "refund-1"}}, context: %{observer: self()}]
{:interrupted, interrupt} = MyApp.ReviewedAgent.invoke(%{messages: ["Refund 25 dollars for order A-1001."]}, opts)
{:ok, review} = HITL.from_interrupt(interrupt)
[request] = review.action_requests
"record_refund" = request.name
"A-1001" = request.args["order_id"]
true = request.args["amount"] == 25

receive do
  {:refund_recorded, _, _} -> raise "The action ran before approval"
after
  0 -> :ok
end
```

The initial tool choice is required because this small agent exists only to
submit a refund. After a tool result, choice becomes none so it can answer
without repeating the action. The checkpointer holds the pending proposal;
no tool execution has occurred.
In your UI, display `HITL.to_map(review)` and the allowed decisions from
`review_configs`. The next block represents the reviewer's explicit approval:

```elixir
{:ok, approved} = MyApp.ReviewedAgent.resume_review([HITL.decision(:approve)], opts)

receive do
  {:refund_recorded, "A-1001", amount} when amount == 25 -> :ok
after
  1_000 -> raise "Approved action did not run"
end

true = Enum.any?(approved.messages, &(&1.role == :tool))
```

Use the same checkpointer and thread ID. Context is not persisted: supply
fresh authenticated caller data on every resume. A durable database
checkpointer is required if reviews must survive process/node restarts.

## Decisions

| Decision | Effect |
| --- | --- |
| `HITL.decision(:approve)` | Execute proposed arguments |
| `HITL.decision(:edit, edited_action: %{name: name, args: args})` | Execute reviewed arguments/action |
| `HITL.decision(:reject, message: reason)` | Skip the action and return rejection feedback |
| `HITL.decision(:respond, message: text)` | Skip execution and use the reviewer's text as the successful tool result |

`:respond` does not mean the original action happened. Use it when a person
supplies the answer or has completed an action separately, and record that
provenance in your application.

An edit is validated before execution. Here a fresh request is edited to a
smaller amount:

```elixir
edited_opts = Keyword.put(opts, :config, %{"configurable" => %{"thread_id" => "refund-2"}})
{:interrupted, _} = MyApp.ReviewedAgent.invoke(%{messages: ["Refund 25 dollars for order A-1002."]}, edited_opts)

decision =
  HITL.decision(:edit, edited_action: %{name: "record_refund", args: %{"order_id" => "A-1002", "amount" => 20}})

{:ok, _} = MyApp.ReviewedAgent.resume_review([decision], edited_opts)

receive do
  {:refund_recorded, "A-1002", 20} -> :ok
after
  1_000 -> raise "Edited action did not run"
end
```

Rejected work must not produce the action's side effect:

```elixir
rejected_opts = Keyword.put(opts, :config, %{"configurable" => %{"thread_id" => "refund-3"}})
{:interrupted, _} = MyApp.ReviewedAgent.invoke(%{messages: ["Refund 25 dollars for order A-1003."]}, rejected_opts)

{:ok, rejected} =
  MyApp.ReviewedAgent.resume_review([HITL.decision(:reject, message: "Do not refund this order.")], rejected_opts)

receive do
  {:refund_recorded, "A-1003", _} -> raise "Rejected action ran"
after
  0 -> :ok
end

true = Enum.any?(rejected.messages, &(BeamWeaver.Core.Message.text(&1) =~ "rejected"))
```

Invalid edits, unsupported decisions or an incorrect decision count return
`:invalid_human_decision` and keep the review pending. Batch edits can replace
the action name; per-call edits keep the tool and replace its arguments.
Edited execution is described in the tool result; `edit_notice:` customizes
that explanatory text.

## Review rules

`interrupt_on` maps tool names to true, false or a rule map:

| Rule | Purpose |
| --- | --- |
| `allowed_decisions` | Restrict approve/edit/reject/respond |
| `when` | Predicate of call, optionally state and runtime |
| `description` | Reviewer-facing text or a function of call and state |
| `args_schema` | JSON Schema for edit validation and UI generation |

A rule map enables review. Invalid rules fail agent construction/invocation;
they do not silently permit execution. Show only permitted decisions in the UI.
Tool-side authorization still applies after human approval.

Review only calls above a local threshold. Application code still decides which caller may invoke this agent:

```elixir
declarations = BeamWeaver.Agent.declarations(MyApp.ReviewedAgent)

{:ok, conditional} =
  BeamWeaver.Agent.build(
    Map.put(declarations, :interrupt_on, %{
      "record_refund" => %{allowed_decisions: [:approve, :reject], when: fn call -> call.args["amount"] > 100 end}
    })
  )

conditional_opts = [
  checkpointer: saver,
  config: %{"configurable" => %{"thread_id" => "conditional-review"}},
  context: %{observer: self()}
]

{:interrupted, pending} =
  BeamWeaver.Agent.invoke(conditional, %{messages: ["Submit a refund of 250 for A-1040."]}, conditional_opts)

{:ok, review} = HITL.from_interrupt(pending)
true = hd(review.action_requests).args["amount"] == 250

{:ok, _} =
  BeamWeaver.Agent.resume_review(conditional, [HITL.decision(:reject, message: "Above local limit")], conditional_opts)
```

## Several calls at once

The default mode batches reviewed calls from a model turn into one review.
Supply one decision per `action_request`, in order. Other calls from that
turn wait and then execute alongside approved actions.

`interrupt_mode: :first` reviews only the first matching call in a turn; use
it only when that narrower policy is intended.

Review a whole model turn with one decision per proposal, preserving the proposal order:

```elixir
batch_opts = [
  checkpointer: saver,
  config: %{"configurable" => %{"thread_id" => "batch-review"}},
  context: %{observer: self()}
]

{:interrupted, pending} =
  MyApp.ReviewedAgent.invoke(
    %{messages: ["Submit two record_refund calls together: 25 dollars for A-1020 and 250 dollars for A-1021."]},
    batch_opts
  )

{:ok, batch_review} = HITL.from_interrupt(pending)
2 = length(batch_review.action_requests)

decisions =
  Enum.map(batch_review.action_requests, fn request ->
    if request.args["order_id"] == "A-1020",
      do: HITL.decision(:approve),
      else: HITL.decision(:reject, message: "Not approved")
  end)

{:ok, _} = MyApp.ReviewedAgent.resume_review(decisions, batch_opts)

receive do
  {:refund_recorded, "A-1020", amount} when amount == 25 -> :ok
after
  1_000 -> raise "Approved action missing"
end

receive do
  {:refund_recorded, "A-1021", _} -> raise "Rejected action ran"
after
  0 -> :ok
end
```

## One pause per call

Use `HumanInTheLoop` middleware with `interrupt_mode: :per_call` and its
`interrupt_on:` rules to review each call independently. Non-reviewed calls
can run immediately. `interrupt.interrupts` lists pending requests; respond
with a map from interrupt ID to decision. Unanswered calls remain paused.

Each call is a separate task in this mode. `concurrent false` does not serialize
those tasks against one another. Put review before retry/error wrappers and
make pre-review behavior safe to repeat. The inline example below checks approved and rejected actions separately.

Configure separate review tasks, inspect each proposal, then answer by interrupt ID. The tool records only approved requests:

```elixir
defmodule MyApp.PerCallReview do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Submit one record_refund call for each requested order in the same turn. Never retry rejected calls."
  tools [MyApp.RecordRefund]

  middleware [
    {BeamWeaver.Agent.Middleware.HumanInTheLoop, interrupt_on: %{"record_refund" => true}, interrupt_mode: :per_call},
    {BeamWeaver.Agent.Middleware.ToolChoice,
     choice: fn request ->
       if Enum.any?(request.messages, &(&1.role == :tool)), do: :none, else: :required
     end}
  ]
end

per_call_opts = [
  checkpointer: saver,
  config: %{"configurable" => %{"thread_id" => "per-call-review"}},
  context: %{observer: self()}
]

{:interrupted, pending} =
  MyApp.PerCallReview.invoke(
    %{messages: ["Submit refunds of 25 for A-1010 and 250 for A-1011, in parallel."]},
    per_call_opts
  )

2 = length(pending.interrupts)

answers =
  Map.new(pending.interrupts, fn entry ->
    decision =
      if entry.value.args["amount"] <= 100,
        do: HITL.decision(:approve),
        else: HITL.decision(:reject, message: "Above review limit")

    {entry.id, decision}
  end)

{:ok, _} = MyApp.PerCallReview.resume_review(answers, per_call_opts)

receive do
  {:refund_recorded, "A-1010", amount} when amount == 25 -> :ok
after
  1_000 -> raise "Approved refund was not recorded"
end

receive do
  {:refund_recorded, "A-1011", _} -> raise "Rejected refund was recorded"
after
  0 -> :ok
end
```

## A new message cancels the review

A new user message on a waiting thread cancels unexecuted calls in that review
and inserts failed tool results before the new message. Already executed
per-call actions retain their results. A stale decision does not identify the
old review: it applies to whatever is currently pending.

Your application must bind a displayed review to a checkpoint/revision and
reject stale submissions. Refresh review cards when a new message or state
update arrives. This also applies to reviews originating in subagents.

Cancel a pending proposal with a new user message and check that its side effect never happens:

```elixir
cancel_opts = [
  checkpointer: saver,
  config: %{"configurable" => %{"thread_id" => "cancel-review"}},
  context: %{observer: self()}
]

{:interrupted, _} = MyApp.ReviewedAgent.invoke(%{messages: ["Refund 25 dollars for A-1030."]}, cancel_opts)
{:ok, _} = MyApp.ReviewedAgent.invoke(%{messages: ["Cancel that refund. Do not submit another action."]}, cancel_opts)
{:ok, saved} = MyApp.ReviewedAgent.get_state(cancel_opts)
[] = saved.interrupts

receive do
  {:refund_recorded, "A-1030", _} -> raise "Cancelled action ran"
after
  0 -> :ok
end
```

## Pause a graph node

Graph interrupts ask for arbitrary data. This complete workflow pauses for a
reviewed reply, then stores it locally:

```elixir
defmodule MyApp.ReplyReview do
  use BeamWeaver.Graph

  graph do
    node :review, &__MODULE__.review/1
    edge start(), :review
    edge :review, finish()
  end

  def review(%{draft: draft}) do
    reply = BeamWeaver.Graph.interrupt(%{question: "Approve or edit this reply", draft: draft})
    %{approved_reply: reply}
  end
end

graph_opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "reply-review"}}]
{:interrupted, paused} = MyApp.ReplyReview.invoke(%{draft: "We are checking your order."}, graph_opts)
"We are checking your order." = paused.value.draft
{:ok, state} = MyApp.ReplyReview.resume("We will check your order today.", graph_opts)
"We will check your order today." = state.approved_reply
```

On resume, the node starts again from its beginning; the saved answer becomes
the interrupt call's return value. Move side effects after the interrupt or
make them idempotent. Keep multiple interrupt calls in a stable order.
Interrupts use a throw; do not swallow them in catch-all exception handling.
Use plain serializable payloads. Tools use review decisions instead of
calling `Graph.interrupt/2` inside their handlers.

## Check the answer

`Graph.interrupt/2` accepts `response_schema:` as a JSON Schema map or schema
module. The pending interrupt exposes that schema for UI construction.
Object answers normalize to string keys. Invalid answers return
`:invalid_resume`, leave the interrupt pending and bypass normal node retry
or error-handler recovery.

A response schema validates the reviewer’s answer before the node continues:

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

An invalid answer keeps the review pending; a valid answer resumes it:

```elixir
MyApp.CheckedReply.resume(%{send: "yes"}, opts)
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_resume}}

{:ok, state} = MyApp.CheckedReply.resume(%{send: true}, opts)
state.sent
#=> "We refunded order A-1003."
```

## Several pauses at once

Parallel graph branches can all pause. Supply a map from interrupt ID to
answer; a single scalar is ambiguous and rejected. In that map, nil leaves
a branch unanswered. Use `Graph.null_resume/0` to explicitly answer nil.

Parallel review nodes each get an interrupt ID. Answer both without depending on completion order:

```elixir
defmodule MyApp.TwoReviews do
  use BeamWeaver.Graph

  graph do
    node :billing, fn _ -> %{billing_ok: BeamWeaver.Graph.interrupt(%{team: "billing"})} end
    node :support, fn _ -> %{support_ok: BeamWeaver.Graph.interrupt(%{team: "support"})} end
    edge start(), :billing
    edge start(), :support
    edge :billing, finish()
    edge :support, finish()
  end
end

parallel_opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "parallel-review"}}]
{:interrupted, pending} = MyApp.TwoReviews.invoke(%{}, parallel_opts)
2 = length(pending.interrupts)
answers = Map.new(pending.interrupts, &{&1.id, true})
{:ok, %{billing_ok: true, support_ok: true}} = MyApp.TwoReviews.resume(answers, parallel_opts)
```

## Pause before or after a step

`interrupt_before` and `interrupt_after` are static breakpoints around graph
nodes (or agent `:model` / `:tools` steps). Continue with `resume(nil, opts)`.
They do not contain a tool review decision. Inspect or edit checkpointed state
before continuing; see [Checkpoints](checkpoints.md).

A static breakpoint pauses without a reviewer payload. Resume with nil:

```elixir
defmodule MyApp.PausedWorkflow do
  use BeamWeaver.Graph
  interrupt_before [:commit]

  graph do
    node :commit, fn _ -> %{recorded: true} end
    edge start(), :commit
    edge :commit, finish()
  end
end

static_opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "static-review"}}]
{:interrupted, _} = MyApp.PausedWorkflow.invoke(%{}, static_opts)
{:ok, %{recorded: true}} = MyApp.PausedWorkflow.resume(nil, static_opts)
```

## Stream a run that pauses

A live stream emits a debug interrupt payload and ends. A collected stream
returns `{:interrupted, interrupt}` with its collected events. Treat the pause
as waiting, not success. See [Streaming](streaming.md#when-the-run-pauses).

A collected stream returns the interrupt and its accumulated events. Resume through the same graph module:

```elixir
stream_opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "stream-review"}}]
{:interrupted, pause} = MyApp.ReplyReview.stream_events(%{draft: "We will investigate."}, stream_opts)
true = is_list(pause.events) and pause.events != []

{:ok, %{approved_reply: "We will investigate today."}} =
  MyApp.ReplyReview.resume("We will investigate today.", stream_opts)
```

## Subgraphs and subagents

Nested pauses propagate to the parent. Resume the parent using the same thread;
its interrupt list includes nested parallel pauses. Subagent tool review uses
`resume_review/2` on the parent. Check the inheritance rules in [Subagents](subagents.md#human-review).

## A review flow for your app

Authorize access to the thread, load current pending state, validate the review
revision, record who decided what, then resume with fresh context. Use durable
storage for delayed decisions and idempotency keys for external actions.
[Storage](storage.md) and [Durable Execution](durable_execution.md) cover those
lifecycle requirements.
