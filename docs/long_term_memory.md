# Long-Term Memory

Long-term memory lets an agent store and recall information across different
conversations, sessions, and threads. Unlike [Short-Term Memory](short_term_memory.md),
which is conversation state persisted by a checkpointer, long-term memory is an
application data store available through `runtime.store` and tool injection.

Use long-term memory for user preferences, profile facts, durable extracted
insights, feature flags, account metadata, and other data that should survive
beyond one thread.

For Deep Agents-style `AGENTS.md` memory files, route virtual paths through
`BeamWeaver.Filesystem.Store` and configure `memory: [...]` on the agent. The
overview in [Memory](memory.md#filesystem-backed-agent-memory) shows
agent-scoped, user-scoped, and organization-scoped memory files. This guide
focuses on the direct `BeamWeaver.Memory` store API.

{% hint style="info" %}
**BeamWeaver Shape**

LangChain's Python docs use LangGraph `InMemoryStore` and `PostgresStore`
passed to `create_agent`. BeamWeaver uses `BeamWeaver.Memory` with explicit
adapters such as `BeamWeaver.Memory.ETS` and `BeamWeaver.Memory.Ecto`, passed
through `store` on `use BeamWeaver.Agent` or `BeamWeaver.Agent.build/1`.
Tools access the store through explicit injected arguments, not Python
`ToolRuntime` type annotations.
{% endhint %}

## Usage

Configure a store on a module-defined agent:

```elixir
defmodule MyApp.MemoryAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  store BeamWeaver.Memory.ETS.new()
end
```

Runtime-built agents use the same concept:

```elixir
alias BeamWeaver.Agent

store = BeamWeaver.Memory.ETS.new()

{:ok, agent} =
  Agent.build(
    name: "memory_agent",
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
    tools: [],
    store: store,
    context_schema: %{
      user_id: %{type: :string, required: true}
    }
  )
```

For durable Postgres-backed storage, use the Ecto adapter:

```elixir
store = BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo)

{:ok, agent} =
  BeamWeaver.Agent.build(
    name: "memory_agent",
    model: BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6"),
    tools: [],
    store: store,
    context_schema: %{user_id: %{type: :string, required: true}}
  )
```

Create the database table in your application migration:

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

{% hint style="warning" %}
**Database Setup**

LangChain's Postgres examples call `store.setup()` from application code.
BeamWeaver does not create tables during agent invocation. Put memory schema
changes in normal Ecto migrations so deploys, rollbacks, and permissions remain
explicit.
{% endhint %}

## Memory Storage

`BeamWeaver.Memory` stores items by namespace and key. A namespace is a list,
atom, or string normalized to string parts. A key is a string or atom. Each item
contains:

| Field | Meaning |
| --- | --- |
| `namespace` | Hierarchical path such as `["users", "user_123", "chitchat"]`. |
| `key` | Distinct item ID within the namespace. |
| `value` | Stored data. Prefer JSON-compatible maps and lists for portable stores. |
| `metadata` | Extra searchable/filterable metadata. |
| `created_at`, `updated_at`, `expires_at` | Adapter-managed timestamps. |

Write, read, and search memory directly:

```elixir
alias BeamWeaver.Memory

store = Memory.ETS.new()
user_id = "user_123"
namespace = ["users", user_id, "chitchat"]

{:ok, _item} =
  Memory.put(
    store,
    namespace,
    "a-memory",
    %{
      "rules" => [
        "User likes short, direct language",
        "User only speaks English and Elixir"
      ],
      "my-key" => "my-value"
    },
    metadata: %{"kind" => "preference"}
  )

{:ok, item} = Memory.get(store, namespace, "a-memory")

items =
  Memory.search(store, ["users", user_id],
    filter: %{"my-key" => "my-value"},
    query: "language preferences"
  )
```

Namespaces can be searched by prefix:

```elixir
Memory.search(store, ["users", user_id], limit: 10)
Memory.list_namespaces(store, prefix: ["users"])
Memory.yield_keys(store, namespace, prefix: "a-")
```

{% hint style="info" %}
**Namespace Rules**

BeamWeaver namespaces cannot be empty, namespace parts cannot be empty or
contain dots, and public namespaces cannot start with `"langgraph"`. This keeps
internal graph bookkeeping and application memory separate.
{% endhint %}

## Indexed Search

`BeamWeaver.Memory.ETS` can maintain a simple embedding index for semantic-ish
search. Provide an embedding model and the fields to index:

```elixir
embedding = BeamWeaver.Models.init_embeddings!("openai:text-embedding-3-small")

store =
  BeamWeaver.Memory.ETS.new(
    index: %{
      embed: embedding,
      dims: 1_536,
      fields: ["profile.summary", "rules[*]"]
    }
  )

{:ok, _item} =
  BeamWeaver.Memory.put(
    store,
    ["users", "user_123"],
    "preferences",
    %{
      "profile" => %{"summary" => "Prefers concise technical answers"},
      "rules" => ["Use direct language", "Prefer Elixir examples"]
    }
  )

BeamWeaver.Memory.search(store, ["users", "user_123"], query: "short Elixir answer")
```

You can disable indexing per write:

```elixir
BeamWeaver.Memory.put(store, ["users", "user_123"], "raw", %{"text" => "draft"}, index: false)
```

{% hint style="warning" %}
**Postgres Vector Search Scope**

LangGraph `PostgresStore` examples accept an index configuration for vector
search. BeamWeaver's `Memory.Ecto` adapter stores JSONB records and supports
namespace, filter, query, TTL, and batch operations through the memory query
layer, but it does not currently manage a pgvector semantic index. Use
`Memory.ETS` for local indexed-memory tests, or implement a custom
`BeamWeaver.Memory.Store` adapter for production vector memory.
{% endhint %}

## Read Long-Term Memory In Tools

Tools read long-term memory by injecting `:store` and, usually, `:context`.
The model does not see injected fields.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Core.{Message, Tool}
alias BeamWeaver.Memory

store = Memory.ETS.new()

{:ok, _item} =
  Memory.put(store, ["users"], "user_123", %{
    "name" => "John Smith",
    "language" => "English"
  })

get_user_info =
  Tool.from_function!(
    name: "get_user_info",
    description: "Look up user information from long-term memory.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "context" => %{"type" => "object"},
        "store" => %{"type" => "object"}
      },
      "required" => ["context", "store"]
    },
    injected: [context: :context, store: :store],
    handler: fn input, _opts ->
      context = input[:context] || input["context"] || %{}
      store = input[:store] || input["store"]
      user_id = context[:user_id] || context["user_id"]

      case Memory.get(store, ["users"], user_id) do
        {:ok, item} -> inspect(item.value)
        :error -> "Unknown user"
        {:error, error} -> {:error, error}
      end
    end
  )

{:ok, agent} =
  Agent.build(
    name: "reader",
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
    tools: [get_user_info],
    store: store,
    context_schema: %{user_id: %{type: :string, required: true}}
  )

Agent.invoke(
  agent,
  %{messages: [Message.user("Look up user information.")]},
  context: %{user_id: "user_123"}
)
```

## Write Long-Term Memory From Tools

Tools can also write memories. Keep write tools narrow: expose only the fields
the model is allowed to update, and derive ownership from trusted runtime
context.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Core.{Message, Tool}
alias BeamWeaver.Memory

store = Memory.ETS.new()

save_user_info =
  Tool.from_function!(
    name: "save_user_info",
    description: "Save user profile information.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "context" => %{"type" => "object"},
        "store" => %{"type" => "object"}
      },
      "required" => ["name", "context", "store"]
    },
    injected: [context: :context, store: :store],
    handler: fn input, _opts ->
      context = input[:context] || input["context"] || %{}
      store = input[:store] || input["store"]
      user_id = context[:user_id] || context["user_id"]
      name = input[:name] || input["name"]

      {:ok, _item} =
        Memory.put(store, ["users"], user_id, %{"name" => name},
          metadata: %{"kind" => "profile"}
        )

      "Successfully saved user info."
    end
  )

{:ok, agent} =
  Agent.build(
    name: "writer",
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
    tools: [save_user_info],
    store: store,
    context_schema: %{user_id: %{type: :string, required: true}}
  )

Agent.invoke(
  agent,
  %{messages: [Message.user("My name is John Smith.")]},
  context: %{user_id: "user_123"}
)

{:ok, item} = Memory.get(store, ["users"], "user_123")
```

{% hint style="warning" %}
**Provider Tabs Collapsed**

LangChain repeats the same memory examples across Google, OpenAI, Anthropic,
OpenRouter, Fireworks, Baseten, and Ollama. BeamWeaver's store API is
provider-independent, so the examples are shown once. BeamWeaver currently has
first-class OpenAI, Anthropic, Google, xAI, fake, and explicit
OpenAI-compatible HTTP paths; the other provider labels are not presented as
supported BeamWeaver workflows until adapters exist.
{% endhint %}

## Batch And Maintenance

Use batch operations when you need to group reads and writes:

```elixir
alias BeamWeaver.Memory
alias BeamWeaver.Memory.{GetOp, ListNamespacesOp, MatchCondition, PutOp, SearchOp}

results =
  Memory.batch(store, [
    %PutOp{namespace: ["users", "user_123"], key: "prefs", value: %{"style" => "brief"}},
    %GetOp{namespace: ["users", "user_123"], key: "prefs"},
    %SearchOp{namespace: ["users"], filter: %{"style" => "brief"}},
    %ListNamespacesOp{match_conditions: [%MatchCondition{type: :prefix, path: ["users"]}]}
  ])
```

Stores also support TTL and retention where the adapter implements it:

```elixir
{:ok, _item} =
  Memory.put(store, ["users", "user_123"], "temporary-note", %{"text" => "expires"}, ttl: 60)

{:ok, _expired_count} = Memory.sweep_expired(store)
{:ok, _pruned_count} = Memory.prune(store, namespace: ["users"], max_entries: 1_000)
```

Use `Memory.async_put/5`, `Memory.async_get/4`, `Memory.async_search/3`, and
other async helpers when memory work should run through BeamWeaver's task-backed
async boundary.

## Related Guides

- [Short-Term Memory](short_term_memory.md)
- [Memory](memory.md)
- [Filesystem](filesystem.md)
- [Filesystem Permissions](permissions.md)
- [Persistence](persistence.md)
- [Runtime](runtime.md)
- [Tools](tools.md)
- [Agents](agents.md)
- [Context Engineering](context_engineering.md)
- [Retrieval](retrieval.md)
- [Graph](graph.md)
- [Adapters](adapters.md)
