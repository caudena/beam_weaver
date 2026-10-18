# How BeamWeaver Works

An agent and a graph share the same execution foundation. The difference is
who chooses the next action: a model inside an agent, or the workflow your
application defines. Start with the [quickstart](quickstart.md) if you want
to run code before reading the concepts.

## Follow one agent request

A caller supplies messages and trusted context. BeamWeaver evaluates the
agent's declarations, prepares instructions/tools and invokes the model.
The model either answers or requests actions. Requested tools execute in
Elixir; their results return to the model. The loop ends with an answer,
an interrupt or an error, subject to the configured limits.

A model cannot read your database merely because its prompt mentions orders.
It needs a tool or supplied data. A tool declaration makes an action available;
it does not prove the model called it. Inspect successful results when the
action matters.

## Separate the five kinds of data

| Data | Who supplies it | Lifetime/use |
| --- | --- | --- |
| Instructions | Application and configured capabilities | Guide each model call |
| Messages | User, model and tool results | Conversation history |
| State | Input plus node/tool/middleware updates | Working data, optionally checkpointed |
| Context | Trusted application caller | One invocation; resend on resume |
| Config | Application runtime settings | Select thread/checkpoint and execution options |

`messages` is a state key with ID-aware merging. Other keys can replace,
accumulate or use specialized channels. Context is not automatically a model
message and is not saved as conversational state. See [Messages](messages.md),
[Runtime Context](runtime_context.md) and [State](graph_state.md).

## Understand the DSL lifecycle

Agent and graph declarations describe how to build a run and are evaluated
when invoked. They can read application configuration. Tool and schema
modules describe their contracts at compilation.

Resource creation needs a separate owner. Repeated declarations must not create
a fresh ETS table or container every call. Pass existing resources through
options or reference supervised services. A database adapter struct is a
handle to a repo, not the process that owns its connections.

## Agents, tools and schemas

An agent combines a model, instructions, tools and policy. A tool describes
an action's arguments and executes application code. A response schema
constrains the final answer consumed by your application. These are separate
contracts even when all use field declarations.

Tool and response fields are required by default. Agent context fields are
optional unless explicitly required. Model-supplied JSON arguments use string
keys; injected runtime values use their declared atom keys.

## Graphs and channels

A graph node reads state and returns changed keys. Edges select subsequent
nodes. A superstep runs currently ready nodes in parallel, then merges their
updates. Several writers to one key need a reducer or another suitable
channel. A join waits for its prerequisite branches.

Graphs can include agents as nested workflows. Dynamic sends distribute work
known only at runtime. Use explicit graph structure where order and routing
must be controlled by application code.

## Threads and checkpoints

A thread ID identifies saved workflow/conversation history. A checkpoint
records state plus what remains to run. Reusing storage and thread identity
continues that history; fresh calls without storage have no past to load.

ETS data disappears with its owner process. Database storage can survive
restarts, but your application must schedule continuation. External actions
may repeat after an ambiguous failure: checkpointing is not an exactly-once
payment or messaging guarantee. See [Durable Execution](durable_execution.md).

## Memory and context management

Conversation history belongs to a thread. Long-term memory stores namespaced
records across threads. Memory files load short Markdown notes into prompts.
Saving a record does not automatically expose it to the model; a tool or prompt
function must retrieve it.

Context management changes the material sent to a finite model window:
request trimming, summarization, file offloading and delegation. Some policies
change saved history; others only change the request. Prompt caching can reduce
repeated prefix processing but does not make the context window larger.

## Middleware and human review

Middleware surrounds model/tool calls and state transitions. It can adjust
requests, select actions, retry failures or impose limits. Before hooks run
forward, after hooks backward, and wrappers nest. Ordering is part of behavior.

An interrupt records a pause. Your application displays the request, obtains
an authorized decision and resumes the correct saved run. Context must be
supplied again. Tool review and dynamic graph input have different resume APIs.

## Streams and task ownership

A live stream starts work when consumed. Reading it twice can execute the
workflow twice. The consumer owns the run; stopping consumption cancels it.
Tokens are provisional until the corresponding model attempt completes.
Handle errors and interrupts as well as text.

For UI work, consume in a task and send selected events to the view. For work
that must outlive the view, use a durable job owner. See [Streaming](streaming.md).

## Deep agents and delegation

A deep agent adds planning, workspace files, skills, memory or subagents to an
ordinary agent. Capabilities add tools and instructions; they do not replace
application permissions. Children can inherit selected context/state/tools,
so define their boundaries explicitly.

## Providers and verification

A `provider:model` identifier selects an adapter and model. Local model profiles
validate known capabilities and parameters. They do not establish account access
or live availability. Actual calls establish the provider integration;
application assertions establish that the requested work happened.

Use fake models for deterministic application tests, real embeddings for search
quality and live provider calls for endpoint behavior. [Testing](testing.md)
explains these boundaries.
