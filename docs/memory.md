# Memory

AI applications need memory to share context across interactions. BeamWeaver has
two memory layers:

- **Short-term memory** is thread-level graph or agent state saved by a
  checkpointer. Use it for multi-turn conversations, resumable workflows, and
  human-in-the-loop pauses.
- **Long-term memory** is namespaced application data saved in a memory store.
  Use it for user preferences, profile facts, durable extracted knowledge, and
  data that should survive across threads.

{% hint style="info" %}
**BeamWeaver Shape**

LangGraph's Python docs show `InMemorySaver`, `PostgresSaver`,
`InMemoryStore`, `PostgresStore`, Python `Runtime[Context]`, and provider tabs.
BeamWeaver uses explicit Elixir adapters:
`BeamWeaver.Checkpoint.ETS`, `BeamWeaver.Checkpoint.Ecto`,
`BeamWeaver.Memory.ETS`, and `BeamWeaver.Memory.Ecto`. Runtime data is
available through `BeamWeaver.Graph.Runtime`, generated agent functions, and
tool injection.
{% endhint %}

Use [Short-Term Memory](short_term_memory.md) for conversation-state details and
[Long-Term Memory](long_term_memory.md) for store, tool, namespace, TTL, batch,
and indexing details.

## Filesystem-Backed Agent Memory

Official Deep Agents makes long-term memory available as files. BeamWeaver
supports the same pattern with three pieces:

1. `memory` points the agent at memory file paths such as `/AGENTS.md` or
   `/memories/preferences.md`.
2. `BeamWeaver.Agent.Middleware.Memory` reads those files before model calls
   and injects their contents into the system prompt as reference material.
3. `BeamWeaver.Filesystem.Store` and `BeamWeaver.Filesystem.Composite` decide
   whether those files are thread-scoped, user-scoped, agent-scoped, or
   organization-scoped.

This is still long-term memory when the memory path is backed by
`BeamWeaver.Memory` storage. Short-term scratch files remain normal graph state
when the path is backed by `BeamWeaver.Filesystem.State`.

{% hint style="info" %}
**Memory Files vs Memory Store**

`memory ["/AGENTS.md"]` loads file contents into the prompt. `store
BeamWeaver.Memory.ETS.new()` gives tools and filesystems durable storage. Use
`BeamWeaver.Filesystem.Store` to bridge the two: the agent sees files, while
the application stores them in `BeamWeaver.Memory`.
{% endhint %}

## How Memory Files Work

Set `memory true` to load `/AGENTS.md`, or pass one or more memory paths:

```elixir
memory ["/memories/AGENTS.md", "/policies/compliance.md"]
```

The middleware loads configured paths in order, strips HTML comments, and wraps
them in an `<agent_memory>` block. It also tells the model to treat memory as
reference material, not as hidden higher-priority system instructions.

When a filesystem is configured, the agent can update writable memory files
through `write_file` or `edit_file`. Use [Filesystem Permissions](permissions.md)
when shared memory should be read-only.

Skills are related but not identical. Memory files are always loaded when
configured. Skills use progressive disclosure: their metadata is visible early,
and the full `SKILL.md` is read only when useful for the task.

## Scoped Filesystem Memory

The namespace you give `BeamWeaver.Filesystem.Store` determines who shares a
memory file.

| Scope | Namespace pattern | Use |
| --- | --- | --- |
| User-scoped | `["users", user_id, "memories"]` | User preferences and profile facts isolated per user. |
| Agent-scoped | `["agents", agent_id, "memories"]` | A single agent identity shared across all users. |
| Organization-scoped | `["orgs", org_id, "policies"]` | Shared policies or knowledge, usually read-only. |
| Agent + user | `["agents", agent_id, "users", user_id]` | Per-user memory isolated within a multi-agent deployment. |

### Agent-Scoped Memory

Agent-scoped memory is shared by every conversation using the same agent
identity. Use it for learned house style, agent self-improvement notes, and
knowledge that should apply to the whole agent.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Filesystem
alias BeamWeaver.Memory

store = Memory.ETS.new()

filesystem =
  Filesystem.Composite.new(
    default: Filesystem.State.new(),
    routes: %{
      "/memories/" =>
        Filesystem.Store.new(store: store, namespace: ["agents", "content-writer", "memories"]),
      "/skills/" =>
        Filesystem.Store.new(store: store, namespace: ["agents", "content-writer", "skills"])
    }
  )

%Filesystem.WriteResult{error: nil} =
  Filesystem.write(
    filesystem,
    "/memories/AGENTS.md",
    """
    ## Response style
    - Keep responses concise
    - Use concrete examples when possible
    """,
    store: store
  )

{:ok, agent} =
  Agent.build(
    model: "openai:gpt-5.4",
    store: store,
    filesystem: filesystem,
    memory: ["/memories/AGENTS.md"],
    skills: ["/skills/"]
  )
```

### User-Scoped Memory

User-scoped memory isolates preferences and facts by the trusted runtime
context. Derive `user_id` from `context`, not from model-provided tool input:

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Filesystem
alias BeamWeaver.Memory

store = Memory.ETS.new()

filesystem =
  Filesystem.Composite.new(
    default: Filesystem.State.new(),
    routes: %{
      "/memories/" =>
        Filesystem.Store.new(
          store: store,
          namespace: fn runtime ->
            user_id = get_in(runtime.context || %{}, [:user_id]) || "anonymous"
            ["users", user_id, "memories"]
          end
        )
    }
  )

{:ok, agent} =
  Agent.build(
    model: "openai:gpt-5.4",
    store: store,
    filesystem: filesystem,
    memory: ["/memories/preferences.md"],
    context_schema: %{user_id: %{type: :string, required: true}}
  )

Agent.invoke(
  agent,
  %{messages: [BeamWeaver.Core.Message.user("Remember that I prefer Elixir examples.")]},
  context: %{user_id: "user-alice"}
)
```

Every user gets a separate `/memories/preferences.md` file because the virtual
path is routed to a namespace derived from runtime context.

### Organization-Level Memory

Organization memory follows the same pattern but uses an organization namespace.
It is usually read-only so one user cannot inject instructions into shared
policy files that other users will read:

```elixir
alias BeamWeaver.Filesystem
alias BeamWeaver.Filesystem.Permission
alias BeamWeaver.Memory

store = Memory.ETS.new()

filesystem =
  Filesystem.Composite.new(
    default: Filesystem.State.new(),
    routes: %{
      "/memories/" =>
        Filesystem.Store.new(
          namespace: fn runtime ->
            ["users", get_in(runtime.context || %{}, [:user_id]), "memories"]
          end
        ),
      "/policies/" =>
        Filesystem.Store.new(
          namespace: fn runtime ->
            ["orgs", get_in(runtime.context || %{}, [:org_id]), "policies"]
          end
        )
    }
  )

permissions = [
  Permission.new(operations: [:write], paths: ["/policies/**"], mode: :deny)
]

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4",
    store: store,
    filesystem: filesystem,
    filesystem_permissions: permissions,
    memory: ["/memories/preferences.md", "/policies/compliance.md"],
    context_schema: %{
      user_id: %{type: :string, required: true},
      org_id: %{type: :string, required: true}
    }
  )
```

Seed organization memory from application code or an administrative workflow,
not from the agent. For example, write to the backing `BeamWeaver.Memory` store
or use `BeamWeaver.Filesystem.write/4` from trusted code before running the
agent.

## Advanced Memory Patterns

| Dimension | BeamWeaver surface |
| --- | --- |
| Duration | Short-term state through checkpointers; long-term data through `BeamWeaver.Memory` stores. |
| Information type | Episodic checkpoints, procedural skills, semantic facts/preferences in files or store records. |
| Scope | Store namespaces derived from agent ID, user ID, org ID, or any trusted runtime context. |
| Update strategy | Hot-path tool writes, application writes, or a separate scheduled consolidation agent. |
| Retrieval | Always-loaded memory files, on-demand skills, direct store search, or custom retrieval tools. |
| Agent permissions | Writable by default when file tools are available; read-only via filesystem permissions or wrapper filesystems. |

### Episodic Memory

Episodic memory is the record of what happened in past conversations. In
BeamWeaver, checkpointed threads are the durable episodic record:

```elixir
records =
  BeamWeaver.Checkpoint.list_records(
    checkpointer,
    %{"configurable" => %{"thread_id" => "thread-123"}},
    limit: 20
  )
```

If an agent should search past conversations, expose a narrow application tool
over your checkpoint adapter or a separate conversation index. Keep user or org
ownership in trusted runtime context, and filter before returning conversation
history to the model.

### Background Consolidation

The default pattern is hot-path memory updates: the agent writes memory while
handling the conversation. For lower user-facing latency or higher quality,
run a separate consolidation agent from your application's scheduler. That
agent can inspect recent checkpoint history, extract durable facts, and merge
them into memory files or direct store records.

BeamWeaver does not implement hosted cron jobs or `langgraph.json`. Use your
application scheduler, Oban, Quantum, Kubernetes CronJobs, or another deployment
mechanism. Keep the schedule aligned with the lookback window so you do not
reprocess the same conversations repeatedly or skip older conversations.

### Read-Only vs Writable Memory

| Permission | Use case | How |
| --- | --- | --- |
| Read-write | User preferences, per-user notes, agent self-improvement, learned skills | Let the agent update files through `write_file` or `edit_file`. |
| Read-only | Organization policy, compliance rules, shared knowledge, developer-owned skills | Populate from application code and deny writes with `BeamWeaver.Filesystem.Permission`. |

Default to user-scoped writable memory unless there is a clear reason to share.
If memory is shared across users, make it read-only or add
human-in-the-loop approval before writes to sensitive paths.

### Concurrent Writes

Multiple threads can write to the same memory namespace. If two threads edit
the same file concurrently, the last successful write may win depending on the
store adapter. Reduce contention by using one file per topic, writing narrow
records directly with `BeamWeaver.Memory`, or consolidating in a scheduled
background agent.

## Short-Term Memory

Short-term memory is graph state scoped by `thread_id`. Agents already include a
`:messages` state channel. Add memory by passing a checkpointer and reusing the
same thread ID for each turn:

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "thread-1"}}

{:ok, _state} =
  MyApp.Agent.invoke(
    %{messages: [Message.user("hi! i am Bob")]},
    checkpointer: checkpointer,
    config: config
  )

{:ok, state} =
  MyApp.Agent.invoke(
    %{messages: [Message.user("what is my name?")]},
    checkpointer: checkpointer,
    config: config
  )

state.messages
```

When building a graph directly, compile it with a checkpointer:

```elixir
alias BeamWeaver.Graph

checkpointer = BeamWeaver.Checkpoint.ETS.new()

graph =
  Graph.new(name: "MemoryGraph")
  |> Graph.add_reducer(:messages, fn existing, update ->
    existing ++ List.wrap(update)
  end)
  |> Graph.add_node(:respond, fn state ->
    %{messages: [BeamWeaver.Core.Message.assistant("Saw #{length(state.messages)} messages")]}
  end)
  |> Graph.add_edge(Graph.start(), :respond)
  |> Graph.add_edge(:respond, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)
```

`thread_id` is the persistent cursor. Reusing it resumes the same checkpointed
history. A new `thread_id` starts a separate thread.

## Production Checkpointing

Use `BeamWeaver.Checkpoint.Ecto` for durable production checkpointing:

```elixir
checkpointer = BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)

MyApp.Agent.invoke(
  %{messages: [BeamWeaver.Core.Message.user("remember this")]},
  checkpointer: checkpointer,
  config: %{"configurable" => %{"thread_id" => "customer-123"}}
)
```

Install the schema with an Ecto migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateBeamWeaverCheckpoints do
  use Ecto.Migration

  def up do
    BeamWeaver.Migrations.up(adapters: [:checkpoint])
  end

  def down do
    BeamWeaver.Migrations.down(adapters: [:checkpoint], version: 1)
  end
end
```

{% hint style="warning" %}
**Database Setup**

LangGraph examples often call `checkpointer.setup()` at runtime. BeamWeaver does
not run persistence migrations from graph or agent invocation. Put database
schema changes in normal Ecto migrations so release ordering, rollback behavior,
and database permissions stay explicit.
{% endhint %}

## Subgraphs

Parent graph checkpointers propagate to subgraphs by default. Compile a child
graph with `checkpointer: true` when it should keep stable subgraph checkpoint
namespaces for inspection, interrupts, or time travel inside the subgraph:

```elixir
child =
  BeamWeaver.Graph.new(name: "Child")
  |> BeamWeaver.Graph.add_node(:step, fn state -> state end)
  |> BeamWeaver.Graph.add_edge(BeamWeaver.Graph.start(), :step)
  |> BeamWeaver.Graph.add_edge(:step, BeamWeaver.Graph.end_node())
  |> BeamWeaver.Graph.compile!(checkpointer: true)
```

See [Time Travel](time_travel.md) and [Persistence](persistence.md) for
checkpoint scope and subgraph replay details.

## Long-Term Memory

Long-term memory stores user-specific or application-specific data across
threads. Configure a store when building an agent:

```elixir
defmodule MyApp.MemoryAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  store BeamWeaver.Memory.ETS.new()
end
```

Runtime-built agents use the same store option:

```elixir
store = BeamWeaver.Memory.ETS.new()

{:ok, agent} =
  BeamWeaver.Agent.build(
    name: "memory_agent",
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
    tools: [],
    store: store,
    context_schema: %{user_id: %{type: :string, required: true}}
  )
```

For production Postgres-backed memory, use the Ecto store:

```elixir
store = BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo)
```

Install its schema with an Ecto migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateBeamWeaverMemory do
  use Ecto.Migration

  def up do
    BeamWeaver.Migrations.up(adapters: [:memory])
  end

  def down do
    BeamWeaver.Migrations.down(adapters: [:memory], version: 1)
  end
end
```

## Access The Store Inside Nodes

Graph nodes can accept `BeamWeaver.Graph.Runtime` as their second argument. The
runtime carries `context`, `store`, and other run-scoped values:

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Memory

call_model = fn state, runtime ->
  user_id = runtime.context.user_id
  namespace = ["memories", user_id]
  query = state.messages |> List.last() |> Message.text()

  memories =
    runtime.store
    |> Memory.search(namespace, query: query, limit: 3)
    |> Enum.map(& &1.value["data"])
    |> Enum.join("\n")

  # Use `memories` in the model call, then write any newly extracted memory.
  {:ok, _item} =
    Memory.put(runtime.store, namespace, Ecto.UUID.generate(), %{
      "data" => "User prefers dark mode"
    })

  %{messages: [Message.assistant("remembered\n#{memories}")]}
end
```

Tools can also read and write long-term memory through injected `:store` and
`:context` arguments. Keep ownership data such as `user_id` in trusted context,
not in model-provided tool input.

## Semantic Search

Enable semantic search in an ETS store by passing an embedding model and the
fields to index:

```elixir
embedding = BeamWeaver.Models.init_embeddings!("openai:text-embedding-3-small")

store =
  BeamWeaver.Memory.ETS.new(
    index: %{
      embed: embedding,
      dims: 1_536,
      fields: ["text"]
    }
  )

{:ok, _item} =
  BeamWeaver.Memory.put(store, ["user_123", "memories"], "1", %{
    "text" => "I love pizza"
  })

BeamWeaver.Memory.search(store, ["user_123", "memories"],
  query: "I'm hungry",
  limit: 1
)
```

{% hint style="warning" %}
**Postgres Vector Search Scope**

`BeamWeaver.Memory.Ecto` stores JSONB records and supports namespace, filter,
query, TTL, and batch operations through the memory query layer. It does not
manage a pgvector semantic index. Use `BeamWeaver.Memory.ETS` for local
indexed-memory tests or implement a custom `BeamWeaver.Memory.Store` adapter
for production vector memory.
{% endhint %}

## Manage Short-Term Memory

Long conversations can exceed a model's context window. BeamWeaver supports the
same management strategies as the official LangGraph guide, mapped to Elixir
APIs.

### Trim Messages

Trim messages before a model call with `BeamWeaver.Core.Messages.Utils.trim/2`.
In an agent, this usually belongs in `before_model` middleware:

```elixir
defmodule MyApp.TrimMessages do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Messages.Utils
  alias BeamWeaver.Graph.Overwrite

  def name(_middleware), do: :trim_messages

  def before_model(state, _runtime) do
    messages = Map.get(state, :messages, [])

    with {:ok, trimmed} <-
           Utils.trim(messages,
             max_tokens: 2_000,
             strategy: :last,
             include_system: true
           ) do
      %{messages: Overwrite.new(trimmed)}
    end
  end
end
```

### Delete Messages

Delete specific messages with `BeamWeaver.Graph.Messages.remove/1` and clear
all messages with `remove_all/0`:

```elixir
alias BeamWeaver.Graph.Messages

def delete_old_messages(%{messages: messages}) when length(messages) > 6 do
  messages
  |> Enum.take(length(messages) - 6)
  |> Enum.map(&Messages.remove(&1.id))
  |> then(&%{messages: &1})
end

def delete_old_messages(_state), do: nil

%{messages: [Messages.remove_all()]}
```

{% hint style="warning" %}
**Provider-Valid Histories**

Deleting messages can leave a provider-invalid transcript. Keep assistant tool
calls paired with matching tool-result messages, and preserve provider-specific
requirements such as system-message placement and first-message role.
{% endhint %}

### Summarize Messages

Use `BeamWeaver.Agent.Middleware.Summarization` to summarize older turns and
retain recent context. The complete middleware setup lives in
[Short-Term Memory](short_term_memory.md#summarize-messages).

This is the BeamWeaver equivalent of LangMem's running-summary pattern, but it
is normal graph state: summaries rewrite the message channel and do not require
a LangMem dependency or a separate long-term store.

## Manage Checkpoints

Inspect the latest state for a thread:

```elixir
config = %{"configurable" => %{"thread_id" => "thread-1"}}

{:ok, snapshot} =
  BeamWeaver.Graph.Compiled.get_state(compiled_graph, config)
```

List checkpoint history, newest first:

```elixir
history =
  BeamWeaver.Graph.Compiled.get_state_history(compiled_graph, config, limit: 20)
```

Use the lower-level checkpoint facade when you need adapter records:

```elixir
records =
  BeamWeaver.Checkpoint.list_records(checkpointer, config, limit: 20)
```

Delete all checkpoints for a thread:

```elixir
:ok = BeamWeaver.Checkpoint.delete_thread(checkpointer, "thread-1")
```

## Database Management

Database-backed adapters need schema migrations before they can be used.
BeamWeaver exposes versioned migration helpers through `BeamWeaver.Migrations`:

- `BeamWeaver.Migrations.up/1`
- `BeamWeaver.Migrations.down/1`
- `BeamWeaver.Migrations.verify_migrated!/1`

Run these from your application's normal Ecto migrations or deployment flow.
Do not rely on graph startup or agent invocation to create tables.

## Related Guides

- [Short-Term Memory](short_term_memory.md)
- [Long-Term Memory](long_term_memory.md)
- [Filesystem](filesystem.md)
- [Filesystem Permissions](permissions.md)
- [Skills](skills.md)
- [Composed Agent Capabilities](agent_harness.md)
- [Persistence](persistence.md)
- [Durable Execution](durable_execution.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Messages](messages.md)
- [Tools](tools.md)
- [Agents](agents.md)
- [Graph](graph.md)
- [Retrieval](retrieval.md)
