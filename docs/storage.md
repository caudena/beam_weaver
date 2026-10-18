# Storage

Choose storage by lifetime and data type. ETS is process-owned in-memory
storage. Ecto adapters use your application's supervised repository; an
adapter struct does not own a pool or create tables automatically.

| Data | In memory | Persistent adapter |
| --- | --- | --- |
| Workflow checkpoints | `Checkpoint.ETS` | `Checkpoint.Ecto`: PostgreSQL or SQLite |
| Namespaced memory | `Memory.ETS` | `Memory.Ecto`: PostgreSQL |
| Cache entries | `Cache.ETS` | `Cache.Ecto`: PostgreSQL |
| Embedded documents | `VectorStore.ETS` | `VectorStore.EctoPostgres`: PostgreSQL with pgvector |

## PostgreSQL setup

Complete [Installation](installation.md). Set `DATABASE_URL` to an **empty
PostgreSQL database reserved for this example**. The server must have pgvector
available for the vector migration below. These blocks run sequentially in
IEx; they make real OpenAI calls and write disposable database records.

In an application, save the repo as `lib/my_app/repo.ex` and migration modules
under `priv/repo/migrations/` with timestamped filenames. The explicit startup
and migration calls below make the standalone IEx flow reproducible.

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
end

defmodule MyApp.Repo.Migrations.AddBeamWeaver do
  use Ecto.Migration
  def up, do: BeamWeaver.Migrations.up(adapters: [:checkpoint, :memory, :cache])
  def down, do: BeamWeaver.Migrations.down(adapters: [:cache, :memory, :checkpoint])
end

{:ok, repo} = MyApp.Repo.start_link(url: System.fetch_env!("DATABASE_URL"), pool_size: 2, log: false)
:ok = Ecto.Migrator.up(MyApp.Repo, 1, MyApp.Repo.Migrations.AddBeamWeaver, log: false)
:ok = BeamWeaver.Migrations.verify_migrated!(repo: MyApp.Repo, adapters: [:checkpoint, :memory, :cache])
```

For normal application startup, configure the repo in your own config files
and add `MyApp.Repo` to your supervision children before components that use it:

```elixir
import Config
config :my_app, ecto_repos: [MyApp.Repo]
config :my_app, MyApp.Repo, url: System.fetch_env!("DATABASE_URL"), pool_size: 10
```

Run `mix ecto.migrate` through your deployment migration process. Do not run
migrations inside agent declarations or on every request.

## Save a real conversation

```elixir
defmodule MyApp.PersistentAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Recall facts supplied in this conversation."
end

saver = BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "storage-example"}}]
{:ok, _} = MyApp.PersistentAgent.invoke(%{messages: ["Remember order A-1001."]}, opts)
{:ok, reply} = MyApp.PersistentAgent.invoke(%{messages: ["Which order did I name?"]}, opts)
true = reply.messages |> List.last() |> BeamWeaver.Core.Message.text() |> String.contains?("A-1001")
{:ok, snapshot} = MyApp.PersistentAgent.get_state(opts)
true = length(snapshot.values.messages) == length(reply.messages)

store = BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo)
{:ok, _} = BeamWeaver.Memory.put(store, ["customers", "ada", "preferences"], "contact", %{"value" => "email"})
{:ok, item} = BeamWeaver.Memory.get(store, ["customers", "ada", "preferences"], "contact")
%{"value" => "email"} = item.value
```

A new adapter value using the same repo reaches the same stored data. Thread
IDs and memory namespaces must be scoped and authorized by your application.
[Durable Execution](durable_execution.md) explains restart scheduling and
idempotency; persistence alone does not restart work automatically.

## Create and upgrade tables

`BeamWeaver.Migrations.up/1` applies missing schema versions for selected
adapters. Add a new application migration when upgrading to a library version
that needs new schema versions; do not edit an already-applied migration.

| Option | Meaning |
| --- | --- |
| `adapters:` | `:checkpoint`, `:memory`, `:cache`, `:vector_store` or `:all` |
| `{adapter, opts}` | Per-adapter table/dimension options |
| `prefix:` | PostgreSQL schema; schema creation can be disabled |
| `version:` on `down` | Roll back selected versions while retaining earlier schema |

Table names and prefixes must match between migration and adapter. Checkpoints
have separate checkpoint/write tables. `verify_migrated!` detects missing or
outdated tables after repo startup. A normal `down` drops selected tables, so
use rollback deliberately.

Memory version 2 retains each record's original TTL. When upgrading older
refresh-on-read data, supplying the historical `default_ttl:` prevents
inferring an overly long lifetime from an already-refreshed expiry.

## Postgres and SQLite

Only the checkpoint Ecto adapter supports SQLite. Add the optional driver in
your consumer app when using it:

```elixir
def deps do
  [{:beam_weaver, "~> 1.0.0"}, {:ecto_sqlite3, "~> 0.25"}]
end
```

The dependency targets the release described in [Installation](installation.md#release-status).
This complete round trip uses a temporary SQLite database:

```elixir
defmodule MyApp.SQLiteRepo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.SQLite3
end

defmodule MyApp.SQLiteCheckpoints do
  use Ecto.Migration
  def up, do: BeamWeaver.Migrations.up(adapters: [:checkpoint])
  def down, do: BeamWeaver.Migrations.down(adapters: [:checkpoint])
end

database = Path.join(System.tmp_dir!(), "beam-weaver-#{System.unique_integer([:positive])}.sqlite3")
{:ok, sqlite_repo} = MyApp.SQLiteRepo.start_link(database: database, pool_size: 1, log: false)

try do
  :ok = Ecto.Migrator.up(MyApp.SQLiteRepo, 1, MyApp.SQLiteCheckpoints, log: false)

  sqlite_opts = [
    checkpointer: BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.SQLiteRepo),
    config: %{"configurable" => %{"thread_id" => "sqlite-example"}}
  ]

  {:ok, _} = MyApp.PersistentAgent.invoke(%{messages: ["Hello."]}, sqlite_opts)
  {:ok, saved} = MyApp.PersistentAgent.get_state(sqlite_opts)
  2 = length(saved.values.messages)
after
  GenServer.stop(sqlite_repo)
  Enum.each([database, database <> "-wal", database <> "-shm"], &File.rm/1)
end
```

## The vector store and pgvector

Choose vector dimensions to match the embedding model. The migration enables
the extension unless `create_extension?: false` delegates that to your database
operator. Indexed vector columns support up to 2,000 dimensions in this adapter;
reduce supported model dimensions or disable the index for larger vectors.

```elixir
defmodule MyApp.Repo.Migrations.AddHelpCenterIndex do
  use Ecto.Migration
  def up, do: BeamWeaver.Migrations.up(adapters: [{:vector_store, dimensions: 1536, index: :hnsw}])
  def down, do: BeamWeaver.Migrations.down(adapters: [:vector_store])
end

:ok = Ecto.Migrator.up(MyApp.Repo, 2, MyApp.Repo.Migrations.AddHelpCenterIndex, log: false)
embeddings = BeamWeaver.Models.init_embeddings!("openai:text-embedding-3-small")
index = BeamWeaver.VectorStore.EctoPostgres.new(repo: MyApp.Repo, embedding: embeddings, namespace: "storage-example")

{:ok, _} =
  BeamWeaver.VectorStore.add_documents(index, [
    BeamWeaver.Core.Document.new!("Refunds take five business days.", id: "refunds"),
    BeamWeaver.Core.Document.new!("Express parcels arrive the next day.", id: "shipping")
  ])

{:ok, [hit]} = BeamWeaver.VectorStore.similarity_search(index, "How long until my refund arrives?", k: 1)
"refunds" = hit.id
```

Distance options are cosine, L2 and inner product; use the same distance in
migration and adapter. Index options include IVFFlat, HNSW or no index.
[Retrieval](retrieval.md) covers chunking, filters and reindexing.

## Serialization

```elixir
alias BeamWeaver.Serialization
alias BeamWeaver.Core.Message
{:ok, encoded} = Serialization.dump(%{message: Message.user("Order A-1001"), state: :open})
{:ok, restored} = Serialization.load(encoded)
:open = restored.state
"Order A-1001" = Message.text(restored.message)
```

Checkpoint/cache serialization uses tagged JSON for supported Elixir values,
including message structs, dates, tuples and atom keys. Loading does not
create new atoms or arbitrary structs. Unknown atom names become strings;
unknown registered tags degrade to field maps with warnings. Keep state
serializable: functions and PIDs cannot be durable state.

Register application structs with stable tags using `Serialization.Registry`
and pass the same registry to writing/reading adapters. Preserve tags across
module renames. Memory values are ordinary JSON maps; use string keys there.

Tagged serialization preserves the supported nested value types:

```elixir
{:ok, json} = Serialization.dump(%{order: %{id: "A-1001", status: :open, lines: [%{sku: "S-1"}]}})
Serialization.load(json)
#=> {:ok, %{order: %{id: "A-1001", status: :open, lines: [%{sku: "S-1"}]}}}
```

Application structs need stable registered tags:

```elixir
defmodule MyApp.Ticket do
  defstruct [:id, :subject]
end
```

Use the same registry for encoding and decoding:

```elixir
ticket = %MyApp.Ticket{id: "ticket-42", subject: "Refund for order A-1001"}
{:error, %BeamWeaver.Core.Error{type: :unsupported_serialization_type}} = Serialization.dump(ticket)

registry = Serialization.Registry.new(types: %{"my_app.ticket" => MyApp.Ticket})
{:ok, json} = Serialization.dump(ticket, serialization: [registry: registry])

Serialization.load(json, serialization: [registry: registry])
#=> {:ok, %MyApp.Ticket{id: "ticket-42", subject: "Refund for order A-1001"}}
```

Without that registration the tag degrades to a field map, not an arbitrary new struct:

```elixir
Serialization.load(json)
#=> {:ok, %{"id" => "ticket-42", "subject" => "Refund for order A-1001"}}
```

## Encryption

`Serialization.Encrypted` uses AES-256-GCM with a 32-byte key. The random key
below is only for this temporary example:

```elixir
key = :crypto.strong_rand_bytes(32)
options = [serialization: [codec: Serialization.Encrypted, encryption_key: key]]
{:ok, ciphertext} = Serialization.dump(Message.user("Private note"), options)
{:ok, decoded} = Serialization.load(ciphertext, options)
"Private note" = Message.text(decoded)

cache =
  BeamWeaver.Cache.Ecto.new(
    repo: MyApp.Repo,
    serialization: [codec: Serialization.Encrypted, encryption_key: key]
  )

:ok = BeamWeaver.Cache.put(cache, "storage-example", "encrypted", %{answer: "ready"}, [])
{:hit, %{answer: "ready"}, _} = BeamWeaver.Cache.lookup(cache, "storage-example", "encrypted", [])
```

Load a persistent key from application secret configuration in production.
Losing it makes encrypted rows unreadable. Wrong keys return serialization
errors. Metadata filtering may need to decrypt rows and cost more than SQL
filtering. The memory adapter's JSON values do not use this checkpoint/cache
codec; protect them at the appropriate storage layer.

## Keep tables small

| Data | Retention |
| --- | --- |
| Checkpoints | Explicit prune/delete or shallow checkpoint mode |
| Memory | TTL in minutes; sweep expired records and prune collections |
| Cache | TTL in milliseconds; sweep expired entries |
| Vectors | Explicit document deletion or indexing cleanup |

Skipped expired entries can remain physically stored until swept. Schedule
cleanup under your application lifecycle, including all tenant namespaces.
For this disposable run, remove its data and stop its repo:

```elixir
:ok = BeamWeaver.Checkpoint.delete_thread(saver, "storage-example")
:ok = BeamWeaver.Memory.delete(store, ["customers", "ada", "preferences"], "contact")
:ok = BeamWeaver.Cache.clear(cache, "storage-example", [])
:ok = BeamWeaver.VectorStore.delete(index, ["refunds", "shipping"])
GenServer.stop(repo)
```

## Write your own adapter

Implement the behavior for checkpoints, memory, cache or vector storage.
`Adapter.Sweepable` and `Adapter.Retainable` are optional cleanup protocols.
Unsupported cleanup must remain an explicit error, not a claimed deletion.
Respect serialization, namespace isolation and failure contracts.
