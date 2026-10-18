# Agents

An agent is a module that gives a model instructions and tools, then runs the
model in a loop until it answers. Use an agent when the model should decide
which steps to take; use a [graph](graphs.md) when you know the steps in advance.

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id, such as A-1001."

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  name "support_agent"
  description "Answers questions about Acme orders."

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday."
    ]

  system_prompt "You are Acme's support agent. Look orders up before you answer."
  tools [MyApp.Tools.LookupOrder]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
result.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Your order A-1001 shipped on Monday."
```

`"fake:chat"` is a scripted model, so the examples on this page run without an
API key: each entry of `responses:` is what the model says on one turn. The
[Quickstart](quickstart.md) builds this agent step by step.

## Declare an agent

`use BeamWeaver.Agent` turns a module into an agent. Inside it, you write
declarations such as `model` and `tools`, one per line, without parentheses.
The module gets `invoke/2`, `stream_events/2`, `resume/2`, `resume_review/2`
and `get_state/1`. Every agent module declares a `model`, and one without it
doesn't compile; to run steps you define instead, write a
[graph module](graphs.md#build-and-run-a-graph) with `use BeamWeaver.Graph`.

To use a real model, change the `model` line. The script goes away, because the
model now decides what to do:

```elixir
model "anthropic:claude-haiku-4-5", temperature: 0.2, timeout: 60_000
```

BeamWeaver evaluates every declaration each time the agent runs, not when the
module compiles: the `model` expression, the options after it, and the rest.
A declaration can therefore read your configuration. That lets tests use the
fake model while production uses a real one (see
[Testing](testing.md#choose-the-model-from-config)):

```elixir
model Application.fetch_env!(:my_app, :support_model), timeout: Application.get_env(:my_app, :model_timeout, 60_000)
```

## Declarations

| Declaration | What it does |
| --- | --- |
| `name "support_agent"` | Names the agent in traces, on its replies, and when another agent delegates to it. Defaults to the module name. |
| `description "..."` | Says what the agent does. A parent agent reads it to decide when to delegate to this one. |
| `model "provider:model", opts` | The chat model and its options. `timeout:` also limits each model step. See [Models](models.md). |
| `system_prompt "..."` | Instructions sent ahead of the conversation on every model call. A string or a system message; it is not stored in the state. |
| `tools [...]` | Tools the model may call. See [Tools](tools.md). |
| `middleware [...]` | Code that runs around model and tool calls, such as retries and limits. See [Middleware](middleware.md). |
| `response_schema MyApp.Schemas.Triage` | Asks for a structured final answer, returned in `result.structured_response`. See [Structured Output](structured_output.md). |
| `response_format strategy` | The same, with a strategy you build yourself, for example from a JSON Schema map. |
| `context_schema do ... end` | Declares and checks the fields of the per-call `context:`. See [Run an agent](#run-an-agent). |
| `interrupt_on %{"issue_refund" => true}` | Pauses before these tools run, so a person can approve them. See [Human-in-the-Loop](human_in_the_loop.md). |
| `interrupt_before [:tools]`, `interrupt_after [:model]` | Pauses every run before or after those steps; `resume/2` continues it. See [Human-in-the-Loop](human_in_the_loop.md#pause-before-or-after-a-step). |
| `checkpointer`, `store`, `cache` | Default storage for calls that don't pass their own. Read the warning below. |
| `recursion_limit 50` | The most steps one run may take. See [How the loop stops](#how-the-loop-stops). |
| `tool_timeout 30_000` | Limits each tool call, in milliseconds; a call that runs longer returns an error to the model. |
| `step_timeout 60_000`, `run_timeout 300_000` | Limit one step, or the whole run, in milliseconds. See [Durable Execution](durable_execution.md). |

`tools` and `middleware` take a list or a block. These two snippets declare
the same agent:

```elixir
model "fake:chat"

tools [MyApp.Tools.LookupOrder]

middleware [
  BeamWeaver.Agent.Middleware.ModelRetry,
  {BeamWeaver.Agent.Middleware.ModelCallLimit, run_limit: 10}
]
```

```elixir
model "fake:chat"

tools do
  tool MyApp.Tools.LookupOrder
end

middleware do
  use BeamWeaver.Agent.Middleware.ModelRetry
  use BeamWeaver.Agent.Middleware.ModelCallLimit, run_limit: 10
end
```

In a block, `include some_list` adds a whole list, such as the tools a helper
function returns. A [toolkit](tools.md#group-tools) module in `tools` adds the
tools it returns, and `tool MyApp.OrderTools, region: "eu"` passes options to
its `tools/1`; other tools take no options.
[Built-in Middleware](builtin_middleware.md) covers each middleware module and
its options.

{% hint style="warning" %}
**Declared storage must outlive the call.** Declarations are evaluated on
every call, so a saver declared as `checkpointer BeamWeaver.Checkpoint.ETS.new()`
would be a new, empty table each time, and the agent would forget every
thread. A module that creates an ETS saver, store or cache in a declaration
doesn't compile. Create them once, in your supervision tree or a test's
`setup`, and pass them per call with `checkpointer:`, `store:` and `cache:`.
{% endhint %}

Declare storage that lives in a database, so every call reaches the same
data, or a function that returns storage you created once, such as
`checkpointer MyApp.AgentStorage.checkpointer()`. When such a function returns
a new ETS saver or store each time, the agent logs a warning on its first
call.

```elixir
checkpointer BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)
store BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo)
```

### Deep agent declarations

These declarations switch on the capabilities of a
[deep agent](deep_agents.md). Each adds middleware, and most add tools or
instructions too.

| Declaration | Adds | Guide |
| --- | --- | --- |
| `filesystem BeamWeaver.Filesystem.State.new()` | File tools such as `read_file` and `write_file` | [Filesystem](filesystem.md) |
| `filesystem_permissions [...]` | Rules for which paths the file tools may use | [Filesystem](filesystem.md) |
| `skills ["/skills"]` | Skills the agent reads when a task needs them | [Skills](skills.md) |
| `memory ["/AGENTS.md"]` | Memory files loaded into the instructions | [Memory Files](memory_files.md) |
| `subagents do subagent MyApp.PolicyExpert end` | The `task` tool, to hand work to other agents | [Subagents](subagents.md) |
| `async_subagents [...]` | Tools to run tasks on remote agents in the background | [Subagents](subagents.md) |
| `execution_mode :research_then_generate` | How the agent runs when it is a subagent | [Subagents](subagents.md) |
| `compact_conversation true` | Summarizes older history, and a tool to do it on demand | [Context Management](context_management.md) |
| `overflow_recovery true` | Recovery when a request is too big for the model | [Context Management](context_management.md) |
| `prompt_caching true` | Provider prompt caching | [Caching](caching.md) |

### Less common declarations

| Declaration | What it does |
| --- | --- |
| `model_opts temperature: 0.2` | Model options, merged over the ones written after `model`. |
| `validate_tools true` | Checks tool-call arguments against the tool schemas first; invalid calls go back to the model without running the tool. |
| `exclude_tools ["lookup_order"]` | Hides tools from the model, including tools that a capability adds. |
| `tool_descriptions %{"lookup_order" => "..."}` | Replaces the descriptions the model sees. |
| `capability_profile :auto` | Applies the [capability profile](profiles.md) of the agent's model, or the profile you give. |
| `input_schema`, `output_schema` | Maps of `BeamWeaver.Agent.Schema.field/3` that the input and the final state must match. Keys they don't declare are dropped. An empty input on a thread with saved state, which continues it, and a `BeamWeaver.Graph.Command` aren't checked. |

## Run an agent

`invoke/2` takes the input state and options, and returns one of three shapes:

- `{:ok, state}`: the run finished. `state.messages` holds the conversation;
  agents with a response schema also return `state.structured_response`.
- `{:interrupted, interrupt}`: the run paused. Continue a tool approval with
  `resume_review/2`, and any other pause with `resume/2`.
- `{:error, %BeamWeaver.Core.Error{}}`: the run failed; `type` says why.

Plain strings in `messages` become user messages; `BeamWeaver.Core.Message`
structs work too. Here the step limit is too small for a tool round, so the
agent answers that it needs more steps (see [How the loop stops](#how-the-loop-stops)):

```elixir
input = %{messages: [BeamWeaver.Core.Message.user("Where is my order A-1001?")]}

case MyApp.SupportAgent.invoke(input, recursion_limit: 2) do
  {:ok, state} -> BeamWeaver.Core.Message.text(List.last(state.messages))
  {:interrupted, _interrupt} -> :waiting_for_review
  {:error, %BeamWeaver.Core.Error{type: type}} -> type
end
#=> "Sorry, need more steps to process this request."
```

These options work on every call:

| Option | What it does |
| --- | --- |
| `checkpointer: saver` | Saves the thread's state after each step. See [Checkpoints and Time Travel](checkpoints.md). |
| `config: %{"configurable" => %{"thread_id" => "ticket-42"}}` | Picks the thread to load and save. |
| `context: %{customer_id: "ada"}` | Per-call data for tools and middleware. See [Runtime Context](runtime_context.md). |
| `store: store` | The memory store for long-term memory. See [Long-Term Memory](long_term_memory.md). |
| `recursion_limit: 25` | Overrides the agent's step limit for this call. |
| `trace: [name: "support-chat", user_id: "ada"]` | Names and tags the run in traces. See [Tracing](tracing.md). |
| `model_opts: [temperature: 0]` | Extra model options for this call. |

With a checkpointer and a thread id, each call continues the conversation:

```elixir
saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, _first} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]}, opts)
{:ok, second} = MyApp.SupportAgent.invoke(%{messages: ["Thanks! Which day again?"]}, opts)

length(second.messages)
#=> 6
```

When a crash or a deploy stopped the last run halfway, for example during a
tool call, call `invoke/2` with an empty input: it finishes that run instead
of starting a new turn. See
[Durable Execution](durable_execution.md#what-survives-a-crash).

An agent that needs per-call data declares it with `context_schema`. Fields
are optional unless you mark them `required: true`, and every call is checked:

```elixir
defmodule MyApp.AccountAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Your account is in good standing."]
  system_prompt "You help Acme customers with their accounts."

  context_schema do
    field :customer_id, :string, required: true
  end
end

MyApp.AccountAgent.invoke(%{messages: ["How is my account?"]})
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_context}}
```

```elixir
{:ok, state} = MyApp.AccountAgent.invoke(%{messages: ["How is my account?"]}, context: %{customer_id: "ada"})
state.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Your account is in good standing."
```

## Stream, pause and inspect

`stream_events/2` with `live: true` returns typed events while the run
progresses: tokens, tool starts and finishes, state updates and the final
message. See [Streaming](streaming.md).

```elixir
{:ok, events} = MyApp.SupportAgent.stream_events(%{messages: ["Where is my order A-1001?"]}, live: true)

for %BeamWeaver.Stream.Envelope{event: %BeamWeaver.Stream.Events.ToolStart{tool_name: name}} <- events,
    do: name
#=> ["lookup_order"]
```

An interrupt pauses a run until you resume it. Here the support agent gets an
`issue_refund` tool that needs approval:

```elixir
defmodule MyApp.Tools.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund an order in full."

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Refunded order #{order_id}."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001"}),
      "I refunded order A-1001."
    ]

  tools [MyApp.Tools.LookupOrder, MyApp.Tools.IssueRefund]
  interrupt_on %{"issue_refund" => true}
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-43"}}]

{:interrupted, interrupt} = MyApp.SupportAgent.invoke(%{messages: ["Please refund order A-1001."]}, opts)
Enum.map(interrupt.value.action_requests, & &1.name)
#=> ["issue_refund"]
```

The paused run is saved in the checkpointer. `resume_review/2` continues it
with the reviewer's decision; [Human-in-the-Loop](human_in_the_loop.md) covers
editing and rejecting calls:

```elixir
{:ok, state} = MyApp.SupportAgent.resume_review([BeamWeaver.Agent.HITL.decision(:approve)], opts)
state.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "I refunded order A-1001."
```

`get_state/1` reads a thread's latest checkpoint without running the agent.
The snapshot's `values` is the saved state:

```elixir
{:ok, snapshot} = MyApp.SupportAgent.get_state(opts)
Enum.map(snapshot.values.messages, & &1.role)
#=> [:user, :assistant, :tool, :assistant]
```

[Checkpoints and Time Travel](checkpoints.md) covers history, forks and
editing state.

## How the loop stops

Each turn, the model either answers or asks for tool calls. BeamWeaver runs the
tools, adds their results to `messages`, and calls the model again. The run
ends when:

- the model replies without tool calls; that reply is the answer;
- the agent has a response schema and the structured answer arrives;
- a tool declared with `return_direct true` runs; its result is the last
  message (see [Tools](tools.md));
- an interrupt pauses the run, returning `{:interrupted, interrupt}`;
- middleware ends it, for example when `ModelCallLimit` reaches its limit;
- the run reaches its step limit.

Every model call, tool round and `before_*` or `after_*` middleware hook is
one step. An agent with tools or middleware may take up to 9,999 steps, so set
`recursion_limit` to bound a runaway loop. When the model asks for tools but
the steps left can't fit the tool round, another model call and the hooks
after it, the agent answers "Sorry, need more steps to process this request."
instead, so the run still ends with an answer. A run that reaches the limit
anyway returns `{:error, %BeamWeaver.Core.Error{type: :recursion_limit}}`.

## Agents built at runtime

When the agent's shape comes from data, such as a tenant's settings,
`BeamWeaver.Agent.build/1` builds it from options named like the declarations
(`response_format:` stands in for `response_schema`). Run it with
`BeamWeaver.Agent.invoke/3`:

```elixir
settings = %{prompt: "You are Acme's support agent.", tools: ["lookup_order"]}
available_tools = %{"lookup_order" => MyApp.Tools.LookupOrder}

{:ok, agent} =
  BeamWeaver.Agent.build(
    name: "support_agent",
    model: "fake:chat",
    model_opts: [responses: ["Order A-1001 shipped on Monday.", "You're welcome!"]],
    system_prompt: settings.prompt,
    tools: Enum.map(settings.tools, &Map.fetch!(available_tools, &1))
  )

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-44"}}]
{:ok, state} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is my order A-1001?"]}, opts)

state.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Order A-1001 shipped on Monday."
```

`build/1` returns `{:ok, agent}`, or `{:error, %BeamWeaver.Core.Error{}}` when
`:model` is missing or invalid, when a tool, middleware entry or response
format is invalid, when an option isn't one of the declarations (the error
names it), or when a subagent can't be built (an `:invalid_subagent` error
that names it; see [Subagents](subagents.md#checked-when-the-agent-is-built)).
`BeamWeaver.Agent.stream_events/3`, `BeamWeaver.Agent.resume/3`,
`BeamWeaver.Agent.resume_review/3` and `BeamWeaver.Agent.get_state/2` take the
built agent as their first argument too.

A built agent takes the call options of an agent module: a call's
`checkpointer:`, `store:` and `cache:` replace the ones given to `build/1`, so
one agent serves every thread:

```elixir
{:ok, _state} = BeamWeaver.Agent.invoke(agent, %{messages: ["Thanks!"]}, opts)
{:ok, snapshot} = BeamWeaver.Agent.get_state(agent, opts)
length(snapshot.values.messages)
#=> 4
```

Prefer agent modules for agents your application defines in code.

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): the agent DSL and the functions that run agents
- [`BeamWeaver.Agent.Built`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Built.html): an agent built at runtime
- [`BeamWeaver.Agent.Middleware`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.html): the middleware behaviour
- [`BeamWeaver.Core.Error`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Error.html): the error returned by failed runs
- [`BeamWeaver.Models.FakeChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.FakeChatModel.html): the scripted model used on this page
