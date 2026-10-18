# Subagents

A subagent is an agent that another agent hands a self-contained task to, with
the `task` tool. Use subagents to keep long research out of the main
conversation, or to give a task to a specialist with its own prompt, model and
tools.

```elixir
defmodule MyApp.PolicyExpert do
  use BeamWeaver.Agent

  name "policy_expert"
  description "Answers questions about Acme's refund and return policies."
  model "fake:chat", responses: ["Yes. Orders can be refunded within 30 days of delivery, so A-1001 qualifies."]
  system_prompt "You know Acme's refund policy. Answer in one or two sentences."
end

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{
        "subagent_type" => "policy_expert",
        "description" => "Order A-1001 was delivered 10 days ago. Can the customer get a refund?"
      }),
      "Good news: order A-1001 can be refunded."
    ]

  system_prompt "You are Acme's support researcher. Ask the policy expert about refund rules."

  subagents do
    subagent MyApp.PolicyExpert
  end
end

alias BeamWeaver.Core.Message

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["Can I get a refund for order A-1001?"]})
Enum.map(result.messages, &{&1.role, Message.text(&1)})
#=> [
#     user: "Can I get a refund for order A-1001?",
#     assistant: "",
#     tool: "Yes. Orders can be refunded within 30 days of delivery, so A-1001 qualifies.",
#     assistant: "Good news: order A-1001 can be refunded."
#   ]
```

The researcher's model called `task`. BeamWeaver ran the policy expert as a
separate run, with the task description as its only message, and returned the
expert's final answer as the tool result. The researcher never sees the
expert's prompt or its intermediate steps.

## When to delegate

- **Keep the main context small.** A subagent's searches, file reads and tool
  results stay in its own run; the parent gets one tool message.
- **Use a specialist** with its own prompt, model, tools and response schema,
  such as a cheaper model for lookups.
- **Work in parallel.** A model can call `task` several times in one turn, and
  the subagents run at the same time.

Don't delegate a one-step lookup; calling the tool directly is cheaper. Don't
delegate work whose steps the parent's model must see: only the answer reaches
it. When you know the steps in advance, use a [graph](graphs.md).

## The task tool

`subagents` gives the agent a `task` tool with two arguments
(`async_subagents` alone doesn't):

| Argument | Meaning |
| --- | --- |
| `subagent_type` | The name of the subagent to run, such as `"policy_expert"`. |
| `description` | The whole assignment. It becomes the subagent's only user message, unless the subagent has `inherit_messages: true`, so it must hold every detail the subagent needs and say what to answer with. |

The tool's description lists every subagent's name and description, with a
few notes on writing a task; a subagent with `inherit_messages: true` is
marked as one that sees the conversation. `subagents` adds nothing to the
system prompt.
Write each subagent's `description` for the parent's model: what the subagent
is for and when to use it. Say in the parent's `system_prompt` when to
delegate.

The parent gets back one tool message: the subagent's last assistant text, or
its [structured answer](#structured-output) as JSON, with the subagent's name
in `metadata.subagent_name`. A failed subagent run doesn't fail the parent:
the message starts with `Subagent error:`, and the parent's model can try
another way. An unknown name gets back the list of valid names, which include
the [general-purpose subagent](#the-general-purpose-subagent) unless you turn
it off.

## Declare subagents

`subagents do ... end` lists agent modules with `subagent`. A subagent module
is an ordinary agent with a `name`, which the parent's model passes as
`subagent_type`, and a `description`. It runs as the module declares it: its
model with the options after it, prompt, tools, middleware, response schema,
`filesystem`, `skills`, `memory`, its own `subagents`, `recursion_limit`,
`tool_timeout`, `step_timeout`, `run_timeout`, `capability_profile` and
`checkpointer`. Agent modules may name each other, or themselves, as
subagents. From the parent it takes only what it leaves out:

- Without `tools`, it gets the parent's `tools`.
- Without `interrupt_on`, it uses the parent's review rules
  ([Human review](#human-review)).
- Without `recursion_limit`, it may take as many steps as the parent's limit.
- Without a `checkpointer` or `store`, it uses the parent's
  ([Context and shared state](#context-and-shared-state)).

It runs its own middleware, not the parent's. To share middleware such as
`ModelRetry` or a PII filter, declare it on both, for example from a function
that returns the list. `base_middleware:` gives a subagent file tools, a task
list or skills built from the parent's settings and files. A middleware of the
same module in the subagent's own list replaces the one built from the
parent's, and runs where its own list puts it.

Options after the module replace what `subagent` reads from it, as in
`subagent MyApp.PolicyExpert, tools: [], name: "refund_judge"`:

| Option | Effect |
| --- | --- |
| `tools:` | Replaces the tools. `[]` gives the subagent none. |
| `model:` | A model value, such as one from `BeamWeaver.Models.init_chat_model!/2`. |
| `name:`, `description:`, `system_prompt:` | Replace the module's values. |
| `capture_output:` | Keeps the answer in the parent's state instead ([Captured outputs](#captured-outputs)). |
| `execution_mode:` | How the subagent runs ([Execution modes](#execution-modes)). |
| `inherit_messages: true` | Starts the subagent with the parent's conversation, without tool calls and their results. The task follows it, after a note that the subagent continues that conversation and should use its facts. |
| `interrupt_on:` | Review rules for the subagent's tools; `false` turns the parent's off ([Human review](#human-review)). |
| `base_middleware:` | Capabilities built from the parent's settings: `BeamWeaver.Agent.Middleware.Filesystem` (file tools), `BeamWeaver.Agent.Middleware.Skills`, `BeamWeaver.Agent.Middleware.TodoList` (a task list), or `:deepagents` for the general-purpose subagent's set: file tools, skills, and the parent's summarization and `compact_conversation` tool. |
| `filesystem:`, `permissions:`, `skills:` | The subagent's filesystem, path rules and skills, also for `base_middleware:` ([Subagent permissions](filesystem.md#subagent-permissions), [Skills for subagents](skills.md#skills-for-subagents)). |

Every other declaration works as an option too, such as `recursion_limit: 20`;
`BeamWeaver.Agent.Subagent.Spec` lists them.

## Structured output

A subagent with a `response_schema` sends its structured answer to the parent
as JSON. Redefine the policy expert with a schema, and the researcher from the
first example gets data it can pass on:

```elixir
defmodule MyApp.Schemas.RefundDecision do
  use BeamWeaver.Schema

  field :eligible, :boolean
  field :reason, :string
end

defmodule MyApp.PolicyExpert do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  name "policy_expert"
  description "Decides whether an order can be refunded under Acme's policy."

  model "fake:chat",
    responses: [FakeChatModel.final(%{eligible: true, reason: "Delivered 10 days ago; the limit is 30 days."})]

  response_schema MyApp.Schemas.RefundDecision
end

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["Can I get a refund for order A-1001?"]})
result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text() |> JSON.decode!()
#=> %{"eligible" => true, "reason" => "Delivered 10 days ago; the limit is 30 days."}
```

The researcher's `subagent MyApp.PolicyExpert` line reads the module on every
run, so it picked up the new definition.

## Captured outputs

With `capture_output: :key`, the subagent's answer goes into the parent's
state under `subagent_outputs`, and the parent's model reads only that the task
is done and its answer was saved. Use it when a specialist's answer is large
and your code, not the parent's model, needs it:

```elixir
defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{
        "subagent_type" => "policy_expert",
        "description" => "Order A-1001 was delivered 10 days ago. Can the customer get a refund?"
      }),
      "Order A-1001 can be refunded."
    ]

  subagents do
    subagent MyApp.PolicyExpert, capture_output: :refund_decision
  end
end

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["Can I get a refund for order A-1001?"]})
result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "The policy_expert subagent finished the task. Its answer was saved as \"refund_decision\" and is not shown here."
```

```elixir
result.subagent_outputs
#=> %{"refund_decision" => %{"eligible" => true, "reason" => "Delivered 10 days ago; the limit is 30 days."}}
```

A structured answer is stored as a map with string keys, a text answer as
text, and a checkpointer saves them with the thread. Asking the same subagent
with the same `description` again in the thread reuses the stored answer
without a new run. A keyword list changes that:
`capture_output: [key: :refund_decision, dedupe: false]` runs the subagent
every time, and `parent_result: :full` in the same list gives the parent's
model the whole answer too.

## Subagents built at runtime

When the specialists come from data, such as a tenant's settings, build each
one with `BeamWeaver.Agent.Subagent.Spec.new/1`:

```elixir
defmodule MyApp.Specialists do
  def all do
    [
      BeamWeaver.Agent.Subagent.Spec.new(
        name: "billing_expert",
        description: "Explains the charges on an Acme invoice.",
        system_prompt: "You explain Acme invoices in one sentence.",
        model: BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["A-1001 was charged once, $49."]),
        tools: []
      )
    ]
  end
end
```

A spec needs a `name` and a `description`, and takes the options of
`BeamWeaver.Agent.build/1`, such as `system_prompt`, `model`, `tools`,
`middleware` and `response_format` (a schema module, as with
`response_schema`), plus the `subagent` options above. Like a module, it uses
the parent's model, tools and review rules when it has none of its own.
Declarations are evaluated on every run, so `include MyApp.Specialists.all()`
in a `subagents` block adds the current list, as in the next example.

## Compiled subagents

`BeamWeaver.Agent.Subagent.Compiled` runs an agent exactly as it is: it
doesn't take the parent's tools or review rules, and options such as
`base_middleware:` don't apply. `agent:` is an agent module or an agent
[built at runtime](agents.md#agents-built-at-runtime). It still uses the
parent's checkpointer, store and recursion limit when it has none of its own.
This researcher mixes all three kinds and asks two subagents at once:

```elixir
defmodule MyApp.OrderHistorian do
  use BeamWeaver.Agent

  name "order_historian"
  model "fake:chat", responses: ["Ada has three orders. A-1003 was refunded on May 2."]
  system_prompt "You summarize a customer's order history."
end

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_calls([
        {"task", %{"subagent_type" => "billing_expert", "description" => "Explain Ada's charges for A-1001."}},
        {"task", %{"subagent_type" => "order_historian", "description" => "Summarize Ada's orders."}}
      ]),
      "You were charged once for A-1001, and A-1003 was refunded on May 2."
    ]

  subagents do
    subagent MyApp.PolicyExpert
    include MyApp.Specialists.all()

    include [
      %BeamWeaver.Agent.Subagent.Compiled{
        name: "order_historian",
        description: "Summarizes a customer's order history.",
        agent: MyApp.OrderHistorian
      }
    ]
  end
end

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["What happened with my orders?"]})
for %{role: :tool} = message <- result.messages, into: %{}, do: {message.metadata.subagent_name, Message.text(message)}
#=> %{
#     "billing_expert" => "A-1001 was charged once, $49.",
#     "order_historian" => "Ada has three orders. A-1003 was refunded on May 2."
#   }
```

## Checked when the agent is built

A subagent is built when a `task` call runs it, so a parent that never
delegates doesn't pay for building its subagents. Each one is checked
earlier, without being built: `BeamWeaver.Agent.build/1` checks them, and an
agent module checks them on its first call. A subagent that can't be built,
such as one with an unknown option, a `middleware` entry that isn't
middleware, two middleware of the same name, a tool that isn't one, a model
that can't be resolved or a response format without a schema, fails the
parent with an `:invalid_subagent` error that names it:

```elixir
{:error, error} =
  BeamWeaver.Agent.build(
    model: "fake:chat",
    subagents: [%{name: "researcher", description: "Researches a question.", tools: ["web_search"]}]
  )

error.message
#=> "subagent \"researcher\": \"web_search\" is not a tool: list modules that `use BeamWeaver.Tool`, tool structs or toolkits"
```

The subagents of a subagent are checked the same way. An agent module checks
its subagents again only when its code changes, so a list that comes from
data, such as `include MyApp.Specialists.all()`, is checked as it was on the
first call.

## The general-purpose subagent

Every agent with `subagents` also gets a subagent named `general-purpose`,
which works as a copy of the parent. It runs the parent's model with the
parent's `tools`, the [file tools](filesystem.md) on the parent's files and
rules, the parent's skills, and the parent's summarization and
`compact_conversation` tool when it has them; it has no task list. What tunes
the parent's tools and prompt tunes it too:

- the tools the parent hides with `exclude_tools` and the descriptions it sets
  with `tool_descriptions`;
- the parent's [capability profile](profiles.md): its text after the
  subagent's prompt, its hidden tools, descriptions and middleware;
- the parent's own `Filesystem`, `Skills`, `Summarization`,
  `CompactConversation` and `ToolCallNormalization` entries in `middleware`,
  in place of the ones the subagent would build, and the parent's own entry
  that replaces a middleware of the profile.

The parent's other middleware, such as a `ModelCallLimit`, stays the
parent's. The subagent's prompt tells it to finish the task on its own and
put the whole answer in its final message, so the parent's model can hand it
any self-contained chunk of work.

A `BeamWeaver.Agent.GeneralPurposeSubagentProfile` in the subagents list
changes it: `description:` and `system_prompt:` replace its texts, and
`enabled: false` leaves it out:

```elixir
model "fake:chat"

subagents do
  subagent MyApp.PolicyExpert
  include [BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)]
end
```

A subagent of your own named `general-purpose` replaces it
([Capability Profiles](profiles.md#the-general-purpose-subagent) shows both).

## Execution modes

`execution_mode` on a subagent module, or the `execution_mode:` option of
`subagent`, sets how the subagent runs:

| Mode | The subagent |
| --- | --- |
| `:agent_loop` (default) | Runs like any agent: it calls tools until it answers. |
| `:structured_once` | Makes one model call, which must give its structured answer. For specialists that only turn the task into data. A `ModelCallLimit` in its own `middleware` replaces the one-call limit. |
| `:research_then_generate` | Runs twice: a tool loop that gathers notes, then one call without tools that turns the task and the notes into its structured answer. |

`:research_then_generate` suits specialists that need tools but must end with
structured data, because the last call doesn't mix tools with a response
schema. A refund auditor that looks orders up with the `lookup_order` tool
from the [Quickstart](quickstart.md) declares:

```elixir
model "anthropic:claude-haiku-4-5"
tools [MyApp.Tools.LookupOrder]
response_schema MyApp.Schemas.RefundDecision
execution_mode :research_then_generate
```

## Context and shared state

A subagent runs with the parent's `context:`
([Runtime Context](runtime_context.md)), so its tools know who the customer
is. It also starts from the parent's state: every key except `messages` and a
few that belong to the parent, such as `todos`, is passed down, and the keys
the subagent changes come back to the parent when it finishes. Files that a
subagent writes with the state filesystem reach the parent this way. The
parent's private keys, such as its call counts and the keys its middleware
declares with `BeamWeaver.Graph.private_channel/2`, stay with the parent.

With a checkpointer, a subagent saves its checkpoints in the parent's thread,
under a checkpoint namespace of its own, so deleting the thread deletes them
too. It uses the parent's checkpointer and store, whether the parent declares
them or gets them per call, unless it declares its own. A subagent with a
checkpointer of its own, under a parent run without a thread, saves in a
thread named after the parent run's `run_id`.

This clerk's tool reads the customer from the context and records a flag in
the state:

```elixir
defmodule MyApp.Tools.FlagForRefund do
  use BeamWeaver.Tool

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command

  name "flag_for_refund"
  description "Flag one of the current customer's orders for a refund."

  injected :context, :context
  injected :tool_call_id, :tool_call_id

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id, context: context, tool_call_id: id}, _opts) do
    flag = "#{context.customer_id}/#{order_id}"
    {:ok, %Command{update: %{refund_flag: flag, messages: [Message.tool("Flagged #{flag}.", tool_call_id: id)]}}}
  end
end

defmodule MyApp.RefundClerk do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  name "refund_clerk"
  description "Flags orders for a refund."

  model BeamWeaver.Models.init_chat_model!("fake:chat",
    responses: [FakeChatModel.tool_call("flag_for_refund", %{"order_id" => "A-1001"}), "Flagged A-1001."]
  )

  tools [MyApp.Tools.FlagForRefund]
end

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{
        "subagent_type" => "refund_clerk",
        "description" => "Flag order A-1001 for a refund."
      }),
      "Order A-1001 is flagged for a refund."
    ]

  subagents do
    subagent MyApp.RefundClerk
  end
end

{:ok, result} =
  MyApp.SupportResearcher.invoke(%{messages: ["Please refund order A-1001."]}, context: %{customer_id: "cus_ada"})

result.refund_flag
#=> "cus_ada/A-1001"
```

## Streaming

A subagent runs inside the parent's `task` call, and its events reach the
parent's stream as they happen: tokens, tool calls, messages and state
updates. Their envelopes have the `namespace` `["tools", "subagent.<name>"]`,
and `metadata` with the `subagent_name` and the `tool_call_id` of the `task`
call, so a UI can show each subagent's steps under the call that started it:

```elixir
alias BeamWeaver.Stream.Events

{:ok, events} =
  MyApp.SupportResearcher.stream_events(%{messages: ["Please refund order A-1001."]},
    live: true,
    context: %{customer_id: "cus_ada"}
  )

for %{event: %Events.ToolStart{tool_name: tool}, namespace: namespace} <- events, do: {namespace, tool}
#=> [{[], "task"}, {["tools", "subagent.refund_clerk"], "flag_for_refund"}]
```

`BeamWeaver.Agent.Subagent.StreamTransformer` turns such a stream into one
summary per subagent run, with its status, values and the subagent runs it
started.

## Human review

A subagent's tools can pause for review, like the parent's
([Human-in-the-Loop](human_in_the_loop.md)). The pause reaches the parent: its
run returns `{:interrupted, interrupt}` with the subagent's review, and
resuming the parent resumes the subagent where it stopped. Here the refund
clerk may flag an order only after a person approves:

```elixir
defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{
        "subagent_type" => "refund_clerk",
        "description" => "Flag order A-1001 for a refund."
      }),
      "Order A-1001 is flagged for a refund."
    ]

  subagents do
    subagent MyApp.RefundClerk, interrupt_on: %{"flag_for_refund" => true}
  end
end

alias BeamWeaver.Agent.HITL

opts = [
  checkpointer: BeamWeaver.Checkpoint.ETS.new(),
  config: %{"configurable" => %{"thread_id" => "ticket-42"}},
  context: %{customer_id: "cus_ada"}
]

{:interrupted, interrupt} = MyApp.SupportResearcher.invoke(%{messages: ["Please refund order A-1001."]}, opts)
{:ok, review} = HITL.from_interrupt(interrupt)
{hd(review.action_requests).name, review.metadata.subagent_name}
#=> {"flag_for_refund", "refund_clerk"}
```

The review's `metadata` names the subagent and the `task` call. Answer it on
the parent:

```elixir
{:ok, result} = MyApp.SupportResearcher.resume_review([HITL.decision(:approve)], opts)
result.refund_flag
#=> "cus_ada/A-1001"
```

A subagent uses the parent's `interrupt_on` rules when it has none of its
own; `interrupt_on: false` on its `subagent` line turns them off. When several
subagents pause in one turn, the parent pauses for one review at a time, in
the order of the `task` calls, and a subagent that already finished doesn't
run again. Decisions that don't fit the review fail the resume with
`:invalid_human_decision`, as for the parent's own tools, and a parent whose
subagents, or their own subagents, review tools refuses to run without a
checkpointer.

A new message to the parent while a subagent's review waits cancels that
review, as it does for the parent's own tools: the `task` call gets a failed
result that says it didn't run, a subagent that already finished keeps its
answer, and the parent's model answers the new message. See [A new message
cancels the review](human_in_the_loop.md#a-new-message-cancels-the-review).

## Async subagents

An async subagent runs a task in the background, on another server or
elsewhere in your application, while the parent keeps talking to the user.
Declare it with `async_subagents`; a client module starts and checks the work.
This client answers at once, where a real one would call a server or start a
job:

```elixir
defmodule MyApp.AuditClient do
  @behaviour BeamWeaver.Agent.Protocol.Client

  @impl true
  def start_task(_spec, _payload, _opts), do: {:ok, %{"thread_id" => "audit-1", "status" => "running"}}

  @impl true
  def check_task(_spec, task_id, _opts),
    do: {:ok, %{"thread_id" => task_id, "status" => "success", "result" => "No duplicate refunds for Ada."}}

  @impl true
  def update_task(_spec, task_id, _message, _opts), do: {:ok, %{"thread_id" => task_id, "status" => "running"}}

  @impl true
  def cancel_task(_spec, task_id, _opts), do: {:ok, %{"thread_id" => task_id, "status" => "cancelled"}}
end

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("start_async_task", %{
        "subagent_type" => "refund_auditor",
        "description" => "Check Ada's refunds this year for duplicates."
      }),
      "I've started audit audit-1. Ask me about it any time.",
      FakeChatModel.tool_call("check_async_task", %{"task_id" => "audit-1"}),
      "The audit is done: no duplicate refunds."
    ]

  async_subagents do
    async_subagent "refund_auditor",
      description: "Audits a customer's refunds in the background.",
      graph_id: "refund_auditor",
      client: MyApp.AuditClient
  end
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["Please audit my refunds."]}, opts)
result.async_tasks["audit-1"].status
#=> "running"
```

The task is recorded in `state.async_tasks` by its id, so a later call on the
same thread can check it:

```elixir
{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["Is the audit done?"]}, opts)
{result.async_tasks["audit-1"].result, result.messages |> List.last() |> Message.text()}
#=> {"No duplicate refunds for Ada.", "The audit is done: no duplicate refunds."}
```

Async subagents give the parent five tools, separate from `task`. Their
descriptions carry the guidance: give the user the full task id, don't poll,
and call again for a status, since one read earlier may be out of date.
Nothing is added to the system prompt:

| Tool | Arguments | Does |
| --- | --- | --- |
| `start_async_task` | `subagent_type`, `description` | Starts a task and records it. |
| `check_async_task` | `task_id` | Fetches the task's status and result. |
| `update_async_task` | `task_id`, `message` | Sends the task more instructions. |
| `cancel_async_task` | `task_id` | Cancels the task. |
| `list_async_tasks` | `status_filter` (optional) | Lists the thread's tasks, refreshing every one that isn't final. |

To add a section to the system prompt, pass `system_prompt:` to
`BeamWeaver.Agent.Middleware.AsyncSubagents.new/1` along with `subagents:`,
and list it in `middleware` in place of `async_subagents`. The section is your
text followed by the list of async subagents.

The client's `start_task/3` gets
`%{assistant_id: graph_id, input: %{messages: [%{role: "user", content: description}]}}`,
and the task id is the `thread_id`, `task_id`, `id` or `run_id` of its reply.
Each callback returns `{:ok, map}` with a `status`, plus a `result` when the
work is done; `success`, `complete`, `completed`, `error`, `timeout` and
`cancelled` are final, and listing doesn't fetch them again. An `interrupted`
task isn't final: a person can resume it on the server, so checking and
listing fetch its status as they do for a running task.

Every callback also gets `parent:` in its opts, a map that says which agent
made the call. With it, a client can run the subagent in its parent's
sandbox, nest the subagent's trace under the parent's, or find a parent's
tasks:

| Key | Holds |
| --- | --- |
| `thread_id` | The parent's thread, from the `config:` of its run; `nil` without one. |
| `run_id` | The parent's run. |
| `tool_call_id` | The async tool call that makes this call. |
| `subagent_name` | The subagent's `name`, as the parent declared it. |
| `trace_id`, `trace_run_id` | The parent's trace and the trace run of that tool call; `nil` outside a traced run. |

Each call builds the map again, so `check_task/3` gets the `tool_call_id` of
the check. To nest the subagent's runs under the parent's trace, start them with
`BeamWeaver.Tracing.start_run(name, trace_id: trace_id, parent_id: trace_run_id)`.
Whoever calls the parent sets its thread config, so a client or a server that
acts on these values, for example to reconnect to a sandbox, checks first that
the caller may use that thread.

An async subagent needs a `client:` or a `url:`; an agent with one that has
neither fails to build. Give an async subagent
`url: "https://agents.acme.example"` instead of a `client:`, and BeamWeaver
uses `BeamWeaver.Agent.Protocol.ReqClient`, which
sends `POST /runs` to start, `GET /runs/:task_id` to check,
`POST /runs/:task_id/input` with `%{message: ...}` to update and
`POST /runs/:task_id/cancel` to cancel, each with the `headers:` you declare.
The start and update requests also carry `metadata` with the
`subagent_name` and the parent's `parent_thread_id` (left out when the parent
has no thread), merged into any `metadata` already in the body; the trace ids
don't leave your application. Any server that answers those requests can run
the work; so can a client of your own that starts supervised work in your
application, such as a `Task.Supervisor` child or an Oban job, and gets the
whole `parent:` map.

## Best practices

- Give each subagent one job, a distinct `description` and only the tools it
  needs, and say in the parent's prompt when to delegate.
- Ask subagents for short answers; have them write large results to files and
  return the paths.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| The parent does the work itself, or picks the wrong subagent. | Make each `description` distinct, and say in the parent's prompt when to delegate. |
| The subagent asks for details the parent has. | Its only input is `description`. Tell the parent's prompt to include every detail. |
| A subagent calls tools it shouldn't have. | It got the parent's tools. Pass `tools:` with the ones it needs. |
| A subagent has no file tools or skills. | Declare `filesystem` and `skills` on its module, or pass `base_middleware:` for the parent's. |
| `build/1` or the first call returns `:invalid_subagent`. | The message names the subagent and what's wrong with it ([Checked when the agent is built](#checked-when-the-agent-is-built)). |
| The run fails with `:missing_checkpointer`. | A subagent, or a subagent of one, reviews tool calls ([Human review](#human-review)); pass `checkpointer:` and a thread id. |
| The parent's model can't see a captured answer. | It only reads that the answer was saved. Read `result.subagent_outputs`, or capture with `parent_result: :full`. |
| A captured subagent doesn't run again. | The same `description` in the same thread reuses the answer. Capture with `dedupe: false`. |
| `check_async_task` returns status `"unknown"`. | The task id isn't in this thread's `async_tasks`. Use the full id and the same thread. |

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): the `subagents`, `async_subagents` and `execution_mode` declarations
- [`BeamWeaver.Agent.Subagent.Spec`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Subagent.Spec.html): subagents built at runtime
- [`BeamWeaver.Agent.Subagent.Compiled`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Subagent.Compiled.html): a whole agent as a subagent
- [`BeamWeaver.Agent.GeneralPurposeSubagentProfile`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.GeneralPurposeSubagentProfile.html): settings for the general-purpose subagent
- [`BeamWeaver.Agent.Subagent.StreamTransformer`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Subagent.StreamTransformer.html): subagent runs from a stream
- [`BeamWeaver.Agent.Subagent.AsyncSpec`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Subagent.AsyncSpec.html): an async subagent
- [`BeamWeaver.Agent.Middleware.Subagents`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Subagents.html): the middleware behind `subagents` and the `task` tool
- [`BeamWeaver.Agent.Middleware.AsyncSubagents`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.AsyncSubagents.html): the async task tools
- [`BeamWeaver.Agent.Middleware.SubagentOutputs`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.SubagentOutputs.html): the `subagent_outputs` state key for your own tools
- [`BeamWeaver.Agent.Protocol.Client`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Protocol.Client.html): the client behaviour for async subagents
- [`BeamWeaver.Agent.Protocol.ReqClient`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Protocol.ReqClient.html): the built-in HTTP client
- [`BeamWeaver.Tools.Subagents`](https://hexdocs.pm/beam_weaver/BeamWeaver.Tools.Subagents.html): the `task` tool as a toolkit
