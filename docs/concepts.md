# Concepts

BeamWeaver builds LLM applications from three kinds of pieces: agents, which
let a model call your tools in a loop; graphs, which run steps you define; and
deep agents, which add planning, files and helpers for long tasks. This page
explains how they fit together and defines the terms the other guides use.

## Agents

An agent is a module that pairs a model with tools. When you invoke it, the
model reads the conversation and either answers or asks for tool calls;
BeamWeaver runs the tools, adds their results to the conversation, and asks
the model again, until it answers without calling a tool.

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "#{order_id} shipped on Monday."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Order A-1001 shipped on Monday."
    ]

  system_prompt "You are Acme's support agent."
  tools [MyApp.Tools.LookupOrder]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]})
Enum.map(result.messages, & &1.role)
#=> [:user, :assistant, :tool, :assistant]
```

The examples in these guides use `"fake:chat"`, a scripted model that needs no
API key: each entry of `responses:` is one model turn. Replace it with a
provider model such as `"openai:gpt-5.4-mini"` to let a real model decide. See
[Agents](agents.md) and [Tools](tools.md).

## Graphs

A graph runs nodes that you write, in an order that you define. Each node is a
function that receives the state and returns the keys it changes. Use a graph
when the steps are known in advance: a pipeline, a router, or a workflow that
waits for people.

```elixir
defmodule MyApp.TicketTriage do
  use BeamWeaver.Graph

  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_node(:classify, &classify/1)
    |> Graph.add_node(:reply, &reply/1)
    |> Graph.add_edge(Graph.start(), :classify)
    |> Graph.add_edge(:classify, :reply)
    |> Graph.add_edge(:reply, Graph.end_node())
  end

  def classify(%{subject: subject}) do
    %{category: if(subject =~ ~r/refund/i, do: :billing, else: :general)}
  end

  def reply(%{category: category}), do: %{reply: "Routed to the #{category} queue."}
end

{:ok, state} = MyApp.TicketTriage.invoke(%{subject: "Refund for order A-1001"})
state.reply
#=> "Routed to the billing queue."
```

A module with `use BeamWeaver.Graph` is a graph module: it runs the graph its
`graph/0` builds. An agent module declares a model and tools instead, and
BeamWeaver builds its graph for it, the loop that calls the model and runs the
tools it asks for; that is why every agent module declares a `model`. Both
kinds of module run with the same functions, such as `invoke/2` and
`resume/2`, so checkpoints, interrupts and streaming work the same way for
both, and either kind can be a node of another graph. Choose a graph when you
know the steps, and an agent when the model should choose them; a graph node
can also call a model or a whole agent. See [Graphs](graphs.md).

## Deep agents

A deep agent is an ordinary agent with more capabilities switched on: a task
list for planning, a filesystem to keep notes and large results out of the
prompt, skills it loads when a task needs them, memory files, and subagents it
can hand self-contained work to. You add each capability with one line:

```elixir
defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  model "anthropic:claude-sonnet-4-6"
  system_prompt "Research a customer's problem across orders and policies, then write up an answer."

  middleware [BeamWeaver.Agent.Middleware.TodoList]
  filesystem BeamWeaver.Filesystem.State.new()
  memory ["/AGENTS.md"]
  skills ["/skills"]
end
```

There is no separate deep-agent type: anything an agent does, a deep agent
does too. See [Deep Agents](deep_agents.md).

## State and messages

Every run reads and writes a **state**, a map. For an agent the main key is
`messages`, the conversation as a list of `%BeamWeaver.Core.Message{}`
structs with a `role` of `:system`, `:user`, `:assistant` or `:tool`. You can
pass plain strings and BeamWeaver turns them into user messages. Graphs and
agents can keep more keys in their state; how each key merges updates is set
by its channel (see [Graph State](graph_state.md)).

## Threads and checkpoints

A **thread** is one conversation or workflow run, named by a `thread_id` you
choose. A **checkpointer** saves the state of a thread after every step. With
one, a later `invoke/2` on the same thread continues where the last one
stopped, and a paused run can resume.

```elixir
saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, _first} = MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]}, opts)
{:ok, second} = MyApp.SupportAgent.invoke(%{messages: ["Thanks!"]}, opts)

length(second.messages)
#=> 6
```

Checkpoints are also what make [human review](human_in_the_loop.md),
[time travel](checkpoints.md) and [durable execution](durable_execution.md)
possible. `Checkpoint.ETS` keeps them in memory for development and tests;
`Checkpoint.Ecto` stores them in Postgres or SQLite.

## Memory

- **Short-term memory** is a thread's own history, kept by the checkpointer.
  Long conversations need [context management](#context-management) so they
  fit in the model's context window. See [Short-Term Memory](short_term_memory.md).
- **Long-term memory** is a **memory store**: namespaced records, such as a
  user's preferences, that outlive any one thread. Tools read and write it.
  See [Long-Term Memory](long_term_memory.md).
- **Memory files** are Markdown files such as `/AGENTS.md` that an agent loads
  into its instructions on every run and edits with its file tools. See
  [Memory Files](memory_files.md).

## Context management

The model only sees what fits in its context window. Context management keeps
long runs inside it: trimming or summarizing old messages, moving large tool
results into files, the `compact_conversation` tool that lets an agent compact
its own history when a task changes, and recovery when a provider rejects an
oversized request. See [Context Management](context_management.md).

The **Compaction Engine** (`BeamWeaver.Compaction`) solves the same problem
for applications that store transcripts themselves, outside agent state. See
[Compaction Engine](compaction_engine.md).

## Middleware

Middleware wraps an agent's model and tool calls. It can change the request,
retry or replace a failing model, pause for approval, redact personal data,
or add tools of its own. Most capabilities above are middleware that an agent
field switches on. See [Middleware](middleware.md) and
[Built-in Middleware](builtin_middleware.md).

## Runtime context

**Runtime context** is per-call data that isn't part of the conversation, such
as the current user's id or permissions. You pass it with `context:` and tools
and middleware read it; the model never sees it unless you put it in a prompt.
See [Runtime Context](runtime_context.md).

## Streaming and interrupts

`stream_events/2` with `live: true` returns typed events while a run
progresses: tokens, tool calls, state updates and the final message. An
**interrupt** pauses a run and returns `{:interrupted, interrupt}`, for example
to ask a person to approve a refund. You continue a tool approval with
`resume_review/2` and the person's decision, and any other pause with
`resume/2`. See [Streaming](streaming.md) and
[Human-in-the-Loop](human_in_the_loop.md).

## Models and providers

A model is named `"provider:model"`, such as `"anthropic:claude-haiku-4-5"`.
Each known model has a **profile** that records what it supports (tools,
structured output, images, context size). Before a request reaches the
provider, BeamWeaver checks the features it asks for, such as tools or
structured output, against the profile. See [Models](models.md) and
[Providers](providers.md).

## Glossary

| Term | Meaning |
| --- | --- |
| Agent | A module with `use BeamWeaver.Agent` that runs a model and tool loop. |
| Tool | A module with `use BeamWeaver.Tool`, or a function, that a model can call. |
| Graph | Nodes and edges you define with `BeamWeaver.Graph`; a module with `use BeamWeaver.Graph` runs one. |
| Deep agent | An agent with planning, a filesystem, skills, memory files or subagents. |
| Subagent | An agent another agent delegates a task to with the `task` tool. |
| State | The map a run reads and updates; for agents it holds `messages`. |
| Thread | One conversation or run, identified by `thread_id`. |
| Checkpointer | Saves a thread's state after each step (`Checkpoint.ETS`, `Checkpoint.Ecto`). |
| Memory store | Namespaced long-term records shared across threads (`Memory.ETS`, `Memory.Ecto`). |
| Memory file | A Markdown file, such as `/AGENTS.md`, loaded into the agent's instructions. |
| Context management | Keeping a run's prompt inside the model's context window. |
| `compact_conversation` | A tool an agent calls to summarize and drop its own older history. |
| Compaction Engine | `BeamWeaver.Compaction`, for transcripts your application stores itself. |
| Runtime context | Per-call data for tools and middleware, passed with `context:`. |
| Middleware | Code that wraps model and tool calls. |
| Interrupt | A pause in a run that waits for a resume value, such as a human decision. |
| Profile | What a model supports, used to validate requests. |

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): the agent DSL and runtime
- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): building graphs and graph modules
- [`BeamWeaver.Checkpoint`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.html): checkpointers
- [`BeamWeaver.Memory`](https://hexdocs.pm/beam_weaver/BeamWeaver.Memory.html): memory stores
- [`BeamWeaver.Models`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.html): models and providers
