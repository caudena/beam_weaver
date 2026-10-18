# Storage

BeamWeaver keeps its data in adapters that you choose: ETS tables in memory for
development and tests, and your own Ecto repo with Postgres (or SQLite for
checkpoints) in production. This page lists what each adapter stores, creates
the tables with migrations, and covers serialization and cleanup.

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Order A-1001 shipped on Monday."]
  system_prompt "You are Acme's support agent."
end

# Development and tests: an in-memory saver, created once.
saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, _result} = MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]}, opts)
{:ok, snapshot} = MyApp.SupportAgent.get_state(opts)
length(snapshot.values.messages)
#=> 2
```

In production only the adapter changes. The Ecto adapters are plain structs
around your repo, so you can build them wherever you need them:

```elixir
opts = [
  checkpointer: BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo),
  store: BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo),
  config: %{"configurable" => %{"thread_id" => "ticket-42"}}
]

MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]}, opts)
```

## What each adapter stores

| Data | Used for | Development and tests | Production | Migration |
| --- | --- | --- | --- | --- |
| Checkpoints | Threads, human review, time travel | `BeamWeaver.Checkpoint.ETS` | `BeamWeaver.Checkpoint.Ecto` (Postgres or SQLite) | `:checkpoint` |
| Memory store | Long-term memory | `BeamWeaver.Memory.ETS` | `BeamWeaver.Memory.Ecto` (Postgres) | `:memory` |
| Cache | Cached graph nodes | `BeamWeaver.Cache.ETS` | `BeamWeaver.Cache.Ecto` (Postgres) | `:cache` |
| Vector store | Retrieval | `BeamWeaver.VectorStore.ETS` | `BeamWeaver.VectorStore.EctoPostgres` (Postgres with pgvector) | `:vector_store` |

ETS tables live on one node and belong to the process that created them, so
create them once, in a test's setup or a long-lived process. The Ecto adapters
hold no state of their own, so any process can build and use them.

## Create the tables

BeamWeaver uses your application's Ecto repo and never creates tables while it
runs. An application without a repo creates one with
`mix ecto.gen.repo -r MyApp.Repo` and configures it:

```elixir
# config/config.exs
import Config
config :my_app, ecto_repos: [MyApp.Repo]

# config/runtime.exs
config :my_app, MyApp.Repo, url: System.get_env("DATABASE_URL"), pool_size: 10
```

Then add a migration that calls `BeamWeaver.Migrations.up/1` with the
adapters you use:

```elixir
defmodule MyApp.Repo.Migrations.AddBeamWeaver do
  use Ecto.Migration

  def up, do: BeamWeaver.Migrations.up(adapters: [:checkpoint, :memory, :cache])
  def down, do: BeamWeaver.Migrations.down(adapters: [:cache, :memory, :checkpoint])
end
```

Then run `mix ecto.migrate`. A migration per feature works just as well:
`up(adapters: [:memory])` for long-term memory, or
`up(adapters: [:vector_store])` for retrieval.

| Option | Meaning |
| --- | --- |
| `adapters:` | Which tables to create: `:checkpoint` (the default), `:memory`, `:cache`, `:vector_store`, or `:all`. `:record_manager` is the table of the record manager that earlier versions had: `:all` doesn't create it, and `down/1` with `:all` or `:record_manager` drops it. |
| `{adapter, opts}` | An entry with options, such as `{:memory, table: "support_memory"}` or `{:vector_store, dimensions: 1024}`. |
| `prefix:` | The Postgres schema for the tables, such as `"agents"`. `up/1` creates it unless you pass `create_schema: false`. The default is `public`. |
| `version:` | For `down/1`: `version: 2` undoes schema version 2 and later and keeps the tables. Without it, `down/1` drops them. |

A table name you change in the migration goes to the adapter too, and so does
`prefix:`: `BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo, table: "support_memory", prefix: "agents")`.
The checkpoint adapter has two tables, `checkpoints_table:` and
`writes_table:`.

`up/1` brings each table to its newest schema version and skips the versions
already applied, so when an upgrade of BeamWeaver adds a schema version, you
add a new migration that calls `up/1` again. To fail fast when a migration is
missing, check at boot, once the repo has started:

```elixir
BeamWeaver.Migrations.verify_migrated!(repo: MyApp.Repo, adapters: [:checkpoint, :memory, :cache])
```

It raises when a table is missing or out of date; on Postgres, the message
names the migration to add.

Memory schema version 2 keeps each record's lifetime, so that reading a
record can start it again. The records already stored get the time from their
last write to their expiry. A store created with `refresh_on_read?: true`
moved the expiry of every record it read, so for those records that time is
longer than their lifetime; give such a store's `default_ttl:` to the
migration, and no record gets a longer lifetime than that:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeBeamWeaverMemory do
  use Ecto.Migration

  def up, do: BeamWeaver.Migrations.up(adapters: [{:memory, default_ttl: 60 * 24}])
  def down, do: BeamWeaver.Migrations.down(adapters: [:memory], version: 2)
end
```

## Postgres and SQLite

`BeamWeaver.Checkpoint.Ecto` runs the same queries on Postgres and SQLite; the
repo you pass decides. All other Ecto adapters need Postgres. For SQLite, add
the driver to your dependencies:

```elixir
def deps do
  [
    {:beam_weaver, "~> 1.0.0"},
    {:ecto_sqlite3, "~> 0.25"}
  ]
end
```

`BeamWeaver.Migrations` reads the database from the repo; on SQLite it
supports only `:checkpoint`.

## The vector store and pgvector

`BeamWeaver.VectorStore.EctoPostgres` keeps embeddings in a pgvector column.
The extension must be installed on the database server; the migration enables
it with `CREATE EXTENSION IF NOT EXISTS vector`, or leaves that to you with
`create_extension?: false`. The column has a fixed size, which must match your
embedding model, and pgvector indexes hold at most 2,000 numbers. Ask a bigger
model for fewer, such as
`init_embeddings!("openai:text-embedding-3-large", dimensions: 1024)`, or keep
all 3,072 with `index: false`, which compares the query with every row:

```elixir
defmodule MyApp.Repo.Migrations.AddHelpCenterIndex do
  use Ecto.Migration

  def up do
    BeamWeaver.Migrations.up(adapters: [{:vector_store, dimensions: 1024, index: :hnsw}])
  end

  def down, do: BeamWeaver.Migrations.down(adapters: [:vector_store])
end
```

| Option | Meaning | Default |
| --- | --- | --- |
| `dimensions:` | Numbers per embedding, such as 1536 for `text-embedding-3-small`; at most 2,000 with an index | `1536` |
| `distance:` | `:cosine`, `:l2` or `:inner_product` | `:cosine` |
| `index:` | `:ivfflat` (tune with `index_opts: [lists: 100]`), `:hnsw` (`index_opts: [m: 16, ef_construction: 64]`), or `false` for no index | `:ivfflat` |
| `create_extension?:` | Run `CREATE EXTENSION IF NOT EXISTS vector` | `true` |

Give the store the same `distance:` as the migration:
`BeamWeaver.VectorStore.EctoPostgres.new(repo: MyApp.Repo, embedding: embeddings, distance: :l2)`.
[Retrieval](retrieval.md) shows the store in use.

## Serialization

Checkpoints and cache entries are saved as JSON. Atoms, tuples, dates and
BeamWeaver's own structs, such as messages and documents, are tagged so that
they load back as the same values:

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Serialization

{:ok, json} = Serialization.dump(Message.user("Where is order A-1001?"))
{:ok, message} = Serialization.load(json)
Message.text(message)
#=> "Where is order A-1001?"
```

Map keys keep their type at any depth, so a thread read back from
`Checkpoint.Ecto` holds what `Checkpoint.ETS` would:

```elixir
{:ok, json} = Serialization.dump(%{order: %{id: "A-1001", status: :open, lines: [%{sku: "S-1"}]}})
Serialization.load(json)
#=> {:ok, %{order: %{id: "A-1001", status: :open, lines: [%{sku: "S-1"}]}}}
```

Atom keys stay JSON object keys, and the object names them under
`"__beam_weaver_atom_keys__"` (`true` when all of its keys are atoms), so the
JSON reads like your data and SQL can query it. A map with other keys, such as
integers, is saved as a list of entries. Loading never creates atoms: a key
whose atom doesn't exist when it loads, because no loaded code uses it, comes
back as a string. Checkpoints saved by earlier versions of BeamWeaver load as
they did, with string keys in nested maps.

Loading never creates arbitrary terms either: only structs on an allowlist
come back. A struct of your own, a PID or a function in the state can't be
saved, and the Ecto adapters return `:unsupported_serialization_type` for it.
Keep state to plain data, or register your struct under a stable tag:

```elixir
defmodule MyApp.Ticket do
  defstruct [:id, :subject]
end
```

```elixir
ticket = %MyApp.Ticket{id: "ticket-42", subject: "Refund for order A-1001"}
{:error, %BeamWeaver.Core.Error{type: :unsupported_serialization_type}} = Serialization.dump(ticket)

registry = Serialization.Registry.new(types: %{"my_app.ticket" => MyApp.Ticket})
{:ok, json} = Serialization.dump(ticket, serialization: [registry: registry])

Serialization.load(json, serialization: [registry: registry])
#=> {:ok, %MyApp.Ticket{id: "ticket-42", subject: "Refund for order A-1001"}}
```

Pass the same registry to the adapters that save your state:
`BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo, serialization: [registry: registry])`.
The tag is what gets stored, so keep it when you rename the module. Memory
store values are saved as JSON as they are; give them string keys (see
[Long-Term Memory](long_term_memory.md#records)).

A value that can't be rebuilt any more doesn't make a checkpoint unreadable.
A struct whose tag isn't in the registry, or whose module was removed, loads
as a map of its fields, and an atom that no loaded code uses loads as a
string. The rest of the checkpoint loads as it was saved, and a warning names
each such tag or atom the first time it loads:

```elixir
Serialization.load(json)
#=> {:ok, %{"id" => "ticket-42", "subject" => "Refund for order A-1001"}}
```

Data that names a struct of its own, with a `__struct__` key, still fails
with `:serialization_error`.

## Encryption

`BeamWeaver.Serialization.Encrypted` wraps the JSON in AES-256-GCM. It needs a
32-byte key, raw with `encryption_key:` or Base64 with `encryption_key_base64:`:

```elixir
key = :crypto.strong_rand_bytes(32)
sealed = [serialization: [codec: Serialization.Encrypted, encryption_key: key]]

{:ok, ciphertext} = Serialization.dump(Message.user("My card ends in 1111."), sealed)
{:ok, message} = Serialization.load(ciphertext, sealed)
Message.text(message)
#=> "My card ends in 1111."
```

Give the same options to the checkpoint and cache adapters, and they encrypt
everything they save, loading the key from your runtime configuration:

```elixir
encrypted = [codec: BeamWeaver.Serialization.Encrypted, encryption_key_base64: System.fetch_env!("BEAM_WEAVER_KEY")]

checkpointer = BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo, serialization: encrypted)
cache = BeamWeaver.Cache.Ecto.new(repo: MyApp.Repo, serialization: encrypted)
```

A wrong key fails with `:serialization_error` instead of returning data, and
a lost key leaves the rows unreadable. The database can't read encrypted
checkpoint metadata, so `BeamWeaver.Checkpoint.list/3` with `filter:` and
`BeamWeaver.Checkpoint.delete_for_runs/2` decrypt the checkpoints to find the
matches, which takes longer on large tables. The memory store saves values as
they are; protect its table with your database's encryption at rest.

## Keep tables small

Expired entries are skipped, and most adapters delete one when they read it,
but an entry nobody reads stays until something deletes it. Plan cleanup for
every table that grows:

| Data | Expiry | Cleanup |
| --- | --- | --- |
| Checkpoints | None: every step adds one | `BeamWeaver.Checkpoint.prune/3` and `BeamWeaver.Checkpoint.delete_thread/2` from a periodic job, or `shallow?: true` on `Checkpoint.Ecto` to keep only the latest (see [Checkpoints and Time Travel](checkpoints.md)) |
| Memory | `ttl:` per record and `default_ttl:` per store, in minutes | `BeamWeaver.Memory.sweep_expired/2` or the sweeper process below, and `BeamWeaver.Memory.prune/2` |
| Cache | `ttl:` per entry, in milliseconds | `BeamWeaver.Cache.sweep_expired/2`; `max_entries:` and `BeamWeaver.Cache.prune/2` on `Cache.ETS` |
| Vectors and records | None | Re-index with cleanup, or delete documents (see [Retrieval](retrieval.md)) |

`BeamWeaver.Memory.TTLSweeper` deletes expired memory records on an interval;
run it under your supervision tree (see
[Going to Production](going_to_production.md#supervision) and
[Long-Term Memory](long_term_memory.md#expiry-and-cleanup)).

## Write your own adapter

An adapter is a struct whose module implements the behaviour for its kind:
`BeamWeaver.Checkpoint.Saver`, `BeamWeaver.Memory.Store`, `BeamWeaver.Cache`
or `BeamWeaver.VectorStore`. Cleanup is
optional: implement the `BeamWeaver.Adapter.Sweepable` protocol for
`sweep_expired/2` and `BeamWeaver.Adapter.Retainable` for `prune/2`. This cache
stores nothing, which turns caching off in tests:

```elixir
defmodule MyApp.NoCache do
  @behaviour BeamWeaver.Cache

  defstruct []

  @impl true
  def lookup(_cache, _namespace, _key, _opts), do: :miss
  @impl true
  def put(_cache, _namespace, _key, _value, _opts), do: :ok
  @impl true
  def delete(_cache, _namespace, _key, _opts), do: :ok
  @impl true
  def clear(_cache, _namespace, _opts), do: :ok
end

defimpl BeamWeaver.Adapter.Sweepable, for: MyApp.NoCache do
  def sweep_expired(_cache, _opts), do: {:ok, 0}
end
```

```elixir
cache = %MyApp.NoCache{}

{BeamWeaver.Cache.sweep_expired(cache), BeamWeaver.Cache.prune(cache)}
#=> {{:ok, 0}, {:error, %BeamWeaver.Core.Error{type: :unsupported_operation}}}
```

For a custom checkpoint saver, see
[Checkpoints and Time Travel](checkpoints.md).

## Reference

- [`BeamWeaver.Migrations`](https://hexdocs.pm/beam_weaver/BeamWeaver.Migrations.html): creating and checking the adapter tables
- [`BeamWeaver.Checkpoint.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.Ecto.html): Postgres and SQLite checkpoints
- [`BeamWeaver.Memory.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Memory.Ecto.html): Postgres memory store
- [`BeamWeaver.Cache.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Cache.Ecto.html): Postgres cache
- [`BeamWeaver.VectorStore.EctoPostgres`](https://hexdocs.pm/beam_weaver/BeamWeaver.VectorStore.EctoPostgres.html): Postgres and pgvector vector store
- [`BeamWeaver.Serialization`](https://hexdocs.pm/beam_weaver/BeamWeaver.Serialization.html): saving and loading values as JSON
- [`BeamWeaver.Serialization.Registry`](https://hexdocs.pm/beam_weaver/BeamWeaver.Serialization.Registry.html): structs allowed to load
- [`BeamWeaver.Serialization.Encrypted`](https://hexdocs.pm/beam_weaver/BeamWeaver.Serialization.Encrypted.html): AES-256-GCM codec
- [`BeamWeaver.Memory.TTLSweeper`](https://hexdocs.pm/beam_weaver/BeamWeaver.Memory.TTLSweeper.html): periodic cleanup of expired memory
- [`BeamWeaver.Adapter.Sweepable`](https://hexdocs.pm/beam_weaver/BeamWeaver.Adapter.Sweepable.html): optional expiry cleanup for adapters
- [`BeamWeaver.Adapter.Retainable`](https://hexdocs.pm/beam_weaver/BeamWeaver.Adapter.Retainable.html): optional pruning for adapters
