# Concepts

An agent chooses actions with a model. A graph follows the workflow you define.
Both operate on state, can stream progress, and can save checkpoints. The
[Quickstart](quickstart.md) runs an agent; [Build an Agent](tutorial.md) adds
a tool and conversation history.

## Agents

An agent module uses `BeamWeaver.Agent` and declares a model. On each turn,
BeamWeaver sends the conversation and available tools to that model. The model
can answer or request tool calls. BeamWeaver executes those calls, adds their
results to the conversation, and calls the model again. The run finishes when
the model answers without requesting another tool, or stops on a limit,
interrupt or error.

A tool is ordinary application code with a model-visible name, description
and input schema. Tool declarations make an action available; they do not
force the model to choose it. Verify calls and arguments when the action
matters to your application. See [Agents](agents.md) and [Tools](tools.md).

## Graphs

A graph gives you control of the steps. A node receives state and returns the
keys it changes. Edges determine which nodes can run next. Conditional edges
branch on results, and joins wait for multiple branches. The graph DSL keeps
these declarations together in `graph do`; the builder API also supports
graphs assembled from data.

Agents and graphs compose: a graph node may invoke an agent, and an agent's
own model/tool loop is implemented as a graph. Choose explicit nodes when
your application must enforce an order; choose an agent when the model should
decide which available actions are needed. See [Graphs](graphs.md).

## State and messages

State is the map a run reads and updates. For agents, its `messages` key
contains the conversation. Messages have roles such as `:user`, `:assistant`
and `:tool`, plus content and optional tool calls. Plain strings passed in
`messages` become user messages. Media uses content blocks.

Each state key has a merge rule. A plain value is replaced by a write;
reducers combine writes, and channels support other behaviors such as
accumulation or transient values. Parallel nodes writing the same key need
an appropriate merge rule. See [Messages](messages.md) and
[Graph State](graph_state.md).

## Threads and checkpoints

A thread ID identifies a conversation or workflow history. A checkpointer
saves state and pending work after steps. Reusing the saver and thread ID
continues that history. Without a checkpointer, a later invocation has no
saved state to load.

ETS storage is local to one node and belongs to the process that created it.
It is useful in development and tests. Database-backed storage survives that
process and application restarts. A checkpoint is evidence of recorded state;
it does not make an external side effect transactional. Retried or resumed
work must handle those effects deliberately. See
[Checkpoints](checkpoints.md), [Storage](storage.md) and
[Durable Execution](durable_execution.md).

## Memory

| Kind | What it retains | Where to learn more |
| --- | --- | --- |
| Short-term memory | A thread's conversation and state, through checkpoints | [Short-Term Memory](short_term_memory.md) |
| Long-term memory | Namespaced records shared across conversations | [Long-Term Memory](long_term_memory.md) |
| Memory files | Instructions and notes read from configured paths | [Memory Files](memory_files.md) |

These mechanisms have different lifetimes. A memory store does not replace a
checkpointer, and saving data in either does not automatically insert all of
it into the model's prompt.

## Context management

A model has a finite context window. Context policies choose what to send:
trim or summarize history, move large results into files, and recover from
oversized requests. The stored conversation and the request sent to a model
need not be identical. See [Context Management](context_management.md).

The [Compaction Engine](compaction_engine.md) provides a separate compaction
interface for applications that manage their own transcripts.

## Middleware

Middleware runs around model and tool calls. It can adjust instructions,
select tools, retry requests, impose limits, redact data or interrupt an
action. Capability declarations add middleware for you; explicit middleware
lets you configure or extend those behaviors. Ordering matters when wrappers
interact. See [Middleware](middleware.md) and
[Built-in Middleware](builtin_middleware.md).

## Runtime context

Runtime context carries per-call application data such as a user, tenant or
permission set. Pass it with `context:`; tools and middleware can read it.
It is not automatically a model-visible message. Keep authentication and
authorization in your application, and expose only the data the model needs.
See [Runtime Context](runtime_context.md).

## Streaming and interrupts

Streaming exposes typed events as a run progresses: model output, tool calls,
state changes and completion. Consume the stream to perform the work, and
handle cancellation and errors explicitly. See [Streaming](streaming.md).

An interrupt pauses execution and returns a value your application can show
to a person. Tool review uses `resume_review`; other interrupts use `resume`.
The application must retain the thread identity and resume the right run.
See [Human-in-the-Loop](human_in_the_loop.md).

## Deep agents

A deep agent is an agent with capabilities for longer tasks: a task list,
filesystem, skills, memory files, subagents or code execution. There is no
separate deep-agent runtime type. Add the capabilities the task needs, then
use the same invocation, streaming and checkpoint interfaces. See
[Deep Agents](deep_agents.md).

## Models and providers

A model identifier names a provider and model, such as
`"openai:gpt-5.4-mini"`. Model profiles describe supported features and limits;
BeamWeaver uses them to validate requests and select compatible behavior.
Account access and service availability are separate from profile validation.

Provider-specific features are documented in [Providers](providers.md).
Use scripted models and replay for deterministic application tests, and live
calls to check your integration with a provider. See [Testing](testing.md).
