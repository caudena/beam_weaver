# Persistence

BeamWeaver persists graph state through explicit checkpoint adapters. When a
graph or agent is compiled with a checkpointer, BeamWeaver saves checkpoint
records as the run advances through graph steps. Those records make
human-in-the-loop flows, conversational memory, state inspection, time travel,
forking, and fault recovery possible.

Persistence is split into two contracts:

- **Checkpointers** save graph execution state for one thread.
- **Memory stores** save namespaced application data across threads.

{% hint style="info" %}
**BeamWeaver Shape**

LangGraph's persistence docs include hosted agent-server behavior where
checkpoint and store infrastructure can be handled for you. BeamWeaver does not
include that hosted server. Applications pass explicit adapters such as
`BeamWeaver.Checkpoint.ETS`, `BeamWeaver.Checkpoint.Ecto`,
`BeamWeaver.Memory.ETS`, or `BeamWeaver.Memory.Ecto` into graphs and agents.
Database setup belongs in your application migrations.
{% endhint %}

## Why Use Persistence

Persistence is required or useful for:

| Capability | Why The Checkpointer Matters |
| --- | --- |
| Human-in-the-loop | The graph can pause, persist state, and resume after a human decision. |
| Short-term memory | Conversation state is scoped by `thread_id` and reused across turns. |
| Time travel | You can inspect, fork, or continue from prior checkpoints. |
| Fault tolerance | Completed sibling writes from a failed super-step can be replayed without rerunning successful work. |
| Debugging | State history shows the values, next nodes, metadata, tasks, and pending writes for a thread. |

Use a memory store when data should outlive one thread: user preferences,
account facts, extracted profile data, durable feature flags, or cross-session
application state.

## Threads

A thread is the stable identifier for one checkpointed execution history.
BeamWeaver reads it from the LangGraph-compatible configurable config:

```elixir
config = %{"configurable" => %{"thread_id" => "support-thread-1"}}
```

Use a new `thread_id` for a separate conversation or workflow run. Reuse the
same `thread_id` when the next invocation should see the same checkpointed
state.

`context:` is separate. It carries per-run values for tools and middleware, such
as `user_id`, request metadata, or permissions. Do not use `context:` as a
persistence key.

## Checkpoints

A checkpoint is a saved snapshot of graph execution. BeamWeaver checkpoints at
execution boundaries and stores enough metadata to restore the thread, inspect
history, and resume interrupted or failed runs.

This graph produces checkpointed state for a simple two-step flow:

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

checkpointer = CheckpointETS.new()

graph =
  Graph.new(name: "CheckpointExample")
  |> Graph.add_reducer(:bar, fn existing, update -> existing ++ List.wrap(update) end)
  |> Graph.add_node(:node_a, fn _state -> %{foo: "a", bar: ["a"]} end)
  |> Graph.add_node(:node_b, fn _state -> %{foo: "b", bar: ["b"]} end)
  |> Graph.add_edge(:node_a, :node_b)
  |> Graph.add_edge(Graph.start(), :node_a)
  |> Graph.add_edge(:node_b, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

config = %{"configurable" => %{"thread_id" => "thread-1"}}

{:ok, state} =
  Compiled.invoke(graph, %{foo: "", bar: []}, config: config)

state.bar
```

The `:bar` reducer accumulates values across nodes. Without a reducer, later
writes overwrite earlier values for the same key.

## Snapshot Fields

`Compiled.get_state/2` returns the latest checkpointed snapshot for a thread:

```elixir
{:ok, snapshot} = Compiled.get_state(graph, config)
```

Common snapshot fields include:

| Field | Meaning |
| --- | --- |
| `values` | Public graph state at the checkpoint. |
| `next` | Node names scheduled to run next. An empty list means the graph completed. |
| `config` | Config containing `thread_id`, `checkpoint_ns`, `checkpoint_id`, and checkpoint maps. |
| `metadata` | Source, step, writes, run, and adapter metadata. |
| `created_at` | Checkpoint timestamp. |
| `parent_config` | Previous checkpoint config, when one exists. |
| `tasks` | Task records for nodes that started or finished around the checkpoint. |
| `next_tasks` | Pending node records for continuation. |
| `pending_writes` | Durable per-task writes that have not yet been committed into a completed super-step. |
| `channel_versions`, `versions_seen`, `updated_channels` | Channel version metadata used for replay and merge behavior. |
| `interrupts` | Pending interrupts observed from checkpoint writes. |

{% hint style="info" %}
**Snapshot Shape**

LangGraph exposes a Python `StateSnapshot` object. BeamWeaver returns Elixir
maps with atom keys for graph-facing fields and nested checkpoint config maps.
The concepts are the same, but the type shape is idiomatic Elixir.
{% endhint %}

## State History

State history is ordered newest first:

```elixir
history =
  Compiled.get_state_history(graph, config, limit: 20)

latest = List.first(history)
```

Use history to find checkpoints by node, step, interrupt, or metadata:

```elixir
before_node_b =
  Enum.find(history, fn snapshot ->
    snapshot.next == ["node_b"]
  end)

manual_updates =
  Enum.filter(history, fn snapshot ->
    snapshot.metadata["source"] == "update"
  end)

interrupted =
  Enum.find(history, fn snapshot ->
    snapshot.interrupts != []
  end)
```

The lower-level checkpoint facade can return typed records for adapter and
exporter code:

```elixir
records =
  BeamWeaver.Checkpoint.list_records(checkpointer, config, limit: 20)
```

## Update State

`Compiled.update_state/4` writes a new checkpoint. It does not mutate an older
checkpoint in place:

```elixir
{:ok, updated_config} =
  Compiled.update_state(graph, config, %{foo: "manual"})

{:ok, snapshot} =
  Compiled.get_state(graph, updated_config)
```

Updates go through the same channel merge logic as node outputs. If a key has a
reducer, the update is accumulated; otherwise it overwrites the current value.

When BeamWeaver can infer the node that should be treated as the source of the
update, it does so. If multiple continuation nodes are possible, pass
`:as_node`:

```elixir
Compiled.update_state(graph, before_node_b.config, %{bar: ["fork"]},
  as_node: :node_a
)
```

`Compiled.bulk_update_state/4` creates a sequence of checkpoint updates with
super-step merge semantics:

```elixir
{:ok, final_config} =
  Compiled.bulk_update_state(graph, config, [
    [%{bar: ["manual-a"]}, %{bar: ["manual-b"]}],
    [%{foo: "after-bulk"}]
  ])
```

## Replay And Fork

A snapshot's `config` contains the `checkpoint_id` needed to revisit that point
in a thread.

Use a prior snapshot config to inspect that checkpoint:

```elixir
{:ok, old_snapshot} =
  Compiled.get_state(graph, before_node_b.config)
```

Use `update_state/4` against a prior checkpoint to fork from there:

```elixir
{:ok, fork_config} =
  Compiled.update_state(graph, before_node_b.config, %{foo: "forked"},
    as_node: :node_a
  )
```

Then invoke or inspect from the returned config. Nodes after the fork point can
run again and may call models or external APIs again. Keep side effects
idempotent or guard them with human review and application-level idempotency
keys.

## Pending Writes

When a super-step fans out to multiple nodes and one node fails, BeamWeaver can
persist successful sibling writes as pending writes. On resume, successful
sibling work does not need to run again.

For example, if `:ok` succeeds and `:fail` fails in the same fan-out step:

```elixir
{:error, _error} = Compiled.invoke(graph, %{}, config: config)
{:ok, snapshot} = Compiled.get_state(graph, config)

snapshot.values
snapshot.pending_writes
snapshot.next
```

The latest state applies pending writes so the application sees recoverable
state. Fetching the raw checkpoint by `snapshot.config` shows the checkpoint
before pending writes were applied.

{% hint style="info" %}
**Fault-Tolerance Boundary**

Pending writes are for durable graph execution. They are not a replacement for
transactional guarantees in external services. Side-effecting tools and nodes
should still use idempotency keys, retries, and explicit compensation logic.
{% endhint %}

## Interrupts

Human-in-the-loop flows require a checkpointer because a paused run must survive
between the interrupt and the resume call:

```elixir
checkpointer = BeamWeaver.Checkpoint.ETS.new()
config = %{"configurable" => %{"thread_id" => "review-thread-1"}}

graph =
  workflow
  |> BeamWeaver.Graph.compile!(checkpointer: checkpointer)

{:interrupted, interrupt} =
  Compiled.invoke(graph, %{draft: "Approve this?"}, config: config)

{:ok, final_state} =
  Compiled.resume(graph, %{interrupt.id => "approved"}, config: config)
```

See [Human-In-The-Loop](human_in_the_loop.md) for the agent middleware and graph
interrupt patterns.

## Memory Store

Checkpointers persist execution state for one thread. Stores persist
application memory across threads:

```elixir
alias BeamWeaver.Memory

store = Memory.ETS.new()
namespace = ["users", "user-123", "memories"]

{:ok, _item} =
  Memory.put(store, namespace, "food", %{
    "memory" => "User likes pizza"
  })

items =
  Memory.search(store, ["users", "user-123"],
    query: "food preferences",
    limit: 3
  )
```

Compile a graph with both:

```elixir
graph =
  workflow
  |> Graph.compile!(
    checkpointer: BeamWeaver.Checkpoint.ETS.new(),
    store: Memory.ETS.new()
  )
```

Agents accept the same concepts through module DSL or `BeamWeaver.Agent.build/1`:

```elixir
defmodule MyApp.MemoryAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  checkpointer BeamWeaver.Checkpoint.ETS.new()
  store BeamWeaver.Memory.ETS.new()
end
```

Tools can access the store through injected `:store` arguments or
`runtime.store`. See [Long-Term Memory](long_term_memory.md) for full examples.

## Checkpointer Adapters

BeamWeaver ships two checkpoint adapters:

| Adapter | Use For | Notes |
| --- | --- | --- |
| `BeamWeaver.Checkpoint.ETS` | Tests, examples, local workflows, lightweight supervised apps. | In-memory and process-local. Not durable across VM restarts. |
| `BeamWeaver.Checkpoint.Ecto` | Durable Postgres-backed deployments. | Uses versioned `BeamWeaver.Migrations` tables for checkpoints plus pending writes. |

Postgres setup is explicit:

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

Then compile with the adapter:

```elixir
checkpointer = BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)
graph = Graph.compile!(workflow, checkpointer: checkpointer)
```

`BeamWeaver.Checkpoint.Ecto.new/1` also supports `shallow?: true`, which keeps
only the latest checkpoint for a thread namespace. Use it when you want
retention-limited resumability and do not need full state history or time
travel.

## Checkpointer Interface

Adapters implement `BeamWeaver.Checkpoint.Saver`. The core callbacks mirror
LangGraph's checkpointer contract while using Elixir return shapes:

| Callback | Purpose |
| --- | --- |
| `get_tuple/2` | Fetch the latest or requested checkpoint tuple. |
| `list/3` | List checkpoint tuples for history. |
| `put/5` | Store a checkpoint. |
| `put_writes/5` | Store per-task pending writes for a checkpoint. |
| `put_checkpoint_with_writes/7` | Optional transactional checkpoint-plus-writes path. |
| `get_delta_channel_history/4` | Retrieve write history for delta channels. |
| `delete_thread/2`, `delete_for_runs/2`, `copy_thread/3`, `prune/3` | Maintenance operations. |
| `next_version/3` | Compute channel version values. |

Public facade functions such as `BeamWeaver.Checkpoint.get_tuple/2`,
`list_records/3`, `copy_thread/3`, `delete_thread/2`, and `prune/3` emit
telemetry and normalize adapter output.

## Storage Optimization

BeamWeaver includes `BeamWeaver.Graph.Channels.DeltaChannel`, used by message
channels and available for append-heavy state. A delta channel checkpoints as
missing or as periodic snapshots and can replay write history from the
checkpointer.

Use it when a channel grows over many turns and replay cost is acceptable:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Channels.DeltaChannel

messages =
  Graph.channel(
    {DeltaChannel, fn existing, updates -> existing ++ List.wrap(updates) end},
    key: :messages,
    initial: []
  )
```

For durable retention, combine channel choice with adapter retention:

```elixir
BeamWeaver.Checkpoint.prune(checkpointer, ["thread-1"])
BeamWeaver.Checkpoint.prune(checkpointer, ["thread-1"], strategy: :delete)
```

## Serialization And Encryption

BeamWeaver uses safe, allowlisted JSON serialization at adapter boundaries
where serialization is required. The serialization layer can also encrypt
payloads with `BeamWeaver.Serialization.Encrypted` when an adapter accepts a
serialization option:

```elixir
serialization: [
  codec: BeamWeaver.Serialization.Encrypted,
  encryption_key: :crypto.strong_rand_bytes(32)
]
```

{% hint style="warning" %}
**Pickle And Encryption Deviation**

LangGraph documents `pickle_fallback` and `EncryptedSerializer` for Python
checkpointers. BeamWeaver does not support pickle or arbitrary term loading.
Use JSON-compatible state values, registered BeamWeaver structs, and explicit
adapter serialization options. Do not assume every adapter encrypts all columns
unless that adapter documents and tests the serialization option you pass.
{% endhint %}

## Unsupported Or Different From Official LangGraph Docs

| Official LangGraph Feature | BeamWeaver Status |
| --- | --- |
| Hosted agent servers automatically handle checkpoint/store infrastructure. | Not built in. Configure adapters explicitly. |
| LangGraph API / Studio default base store. | Not built in. Pass `store:` explicitly. |
| `checkpointer.setup()` / `store.setup()` in application code. | Use Ecto migrations via `BeamWeaver.Migrations.up/1`. |
| SQLite, Redis, MongoDB, Azure Cosmos DB checkpointers. | Not currently documented as BeamWeaver adapters. |
| Python async saver methods like `.aput` and `.alist`. | BeamWeaver uses synchronous callbacks plus `async_*` facade helpers backed by `BeamWeaver.Core.Async`. |
| Python `StateSnapshot`, `PregelTask`, `RunnableConfig`. | BeamWeaver returns Elixir maps/records and config maps. |
| `pickle_fallback`. | Not supported. |
| Hosted semantic-search store config in `langgraph.json`. | Not supported. Configure BeamWeaver memory adapters in Elixir. |
| Postgres memory vector index managed by `PostgresStore`. | `Memory.Ecto` stores/searches JSONB records but does not manage pgvector semantic indexing. |

## Related Guides

- [Durable Execution](durable_execution.md)
- [Fault Tolerance](fault_tolerance.md)
- [Short-Term Memory](short_term_memory.md)
- [Long-Term Memory](long_term_memory.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Graph](graph.md)
- [Runtime](runtime.md)
- [Event Streaming](event_streaming.md)
- [Adapters](adapters.md)
- [Tracing](tracing.md)
