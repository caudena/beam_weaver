# Adapters

BeamWeaver keeps durable runtime dependencies explicit. Applications pass cache,
checkpoint, memory, vectorstore, and record-manager adapters into graphs or
agents; runtime code depends on behaviours, not Ecto modules.

Implemented local adapters include:

- `BeamWeaver.Checkpoint.ETS` and `BeamWeaver.Checkpoint.Ecto`
- `BeamWeaver.Cache.ETS` and `BeamWeaver.Cache.Ecto`
- `BeamWeaver.Memory.ETS` and `BeamWeaver.Memory.Ecto`
- `BeamWeaver.VectorStore.ETS` and `BeamWeaver.VectorStore.EctoPostgres`
- `BeamWeaver.Indexing.RecordManager.ETS`
- `BeamWeaver.Indexing.RecordManager.EctoPostgres`

Setup is explicit:

```elixir
defmodule MyApp.Repo.Migrations.AddBeamWeaverAdapters do
  use Ecto.Migration

  def up do
    BeamWeaver.Migrations.up(adapters: [:checkpoint, :memory, :cache])
  end

  def down do
    BeamWeaver.Migrations.down(adapters: [:cache, :memory, :checkpoint], version: 1)
  end
end
```

Normal runtime calls never create database tables automatically.

Durable adapters use `BeamWeaver.Serialization` by default. The default JSON
codec is type-tagged and allowlisted; encrypted checkpoint/store payloads can
opt in to `BeamWeaver.Serialization.Encrypted` with an explicit 32-byte
AES-256-GCM key:

```elixir
serialization: [
  codec: BeamWeaver.Serialization.Encrypted,
  encryption_key: :crypto.strong_rand_bytes(32)
]
```

Live Postgres tests use `BEAM_WEAVER_POSTGRES_URL`; point it at a disposable
BeamWeaver test database.

## Related Guides

- [Persistence](persistence.md)
- [Memory](memory.md)
- [Long-Term Memory](long_term_memory.md)
- [Retrieval](retrieval.md)
- [Core](core.md)
