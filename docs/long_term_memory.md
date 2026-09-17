# Long-Term Memory

Long-term memory lets an agent store and recall information across different
conversations, sessions, and threads. Unlike [Short-Term Memory](short_term_memory.md),
which is conversation state persisted by a checkpointer, long-term memory is an
application data store available through `runtime.store` and tool injection.

Use long-term memory for user preferences, profile facts, durable extracted
insights, feature flags, account metadata, and other data that should survive
beyond one thread.

This guide covers memory kept as records in a `BeamWeaver.Memory` store: how a
record is addressed, how to keep the memories of different users, projects, and
organizations apart, and how to give an agent tools and a prompt over them.
Memory kept in plain `AGENTS.md` files on disk is covered in
[Memory](memory.md#memory-files).

{% hint style="info" %}
**Stores And Injection**

`BeamWeaver.Memory` is the API, and a store is an explicit adapter such as
`BeamWeaver.Memory.ETS` or `BeamWeaver.Memory.Ecto`, given to an agent with
`store` on `use BeamWeaver.Agent` or `BeamWeaver.Agent.build/1`. Tools reach
the store through explicit injected arguments.
{% endhint %}

## Usage

A store is given to an agent with `store`. `BeamWeaver.Memory.Ecto` keeps
memories in Postgres. Its handle is a plain struct, so it can be declared in a
module-defined agent:

```elixir
defmodule MyApp.MemoryAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  store BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo)

  context_schema do
    field :user_id, :string, required: true
  end
end
```

Runtime-built agents take the same store:

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

`BeamWeaver.Memory.ETS` keeps memories in ETS tables of the running node. They
are gone when the VM stops, which suits tests and local development. `new/1`
creates the tables, so call it once, keep the store, and pass it to every run:

```elixir
store = BeamWeaver.Memory.ETS.new()

MyApp.MemoryAgent.invoke(
  %{messages: [BeamWeaver.Core.Message.user("Hello")]},
  store: store,
  context: %{user_id: "ada"}
)
```

A `store:` passed with a run replaces the store declared in the agent module,
which is also how a test swaps Postgres for ETS.

{% hint style="warning" %}
**Create An ETS Store Once**

The declarations of an agent module are evaluated for every run. `store
BeamWeaver.Memory.ETS.new()` in a module therefore starts every run with a new,
empty store, and nothing is remembered from one run to the next. Create the ETS
store once, for example when your application starts, and pass it with `store:`.
{% endhint %}

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
    query: "direct language"
  )
```

Without an [index](#indexed-search), `query:` keeps the items whose value or
metadata contains the text, ignoring case. It does not match by meaning.

With `BeamWeaver.Memory.Ecto` an item is one row of the memory table
(`beam_weaver_memory_items` unless you pass `table:`): `namespace` is a `text[]`
column, `value` and `metadata` are `jsonb`, and the primary key is
`(namespace, key)`. `BeamWeaver.Memory.ETS` keeps the same items in an ETS table
for tests and single-node development. Code written against `BeamWeaver.Memory`
runs unchanged on both.

## Namespaces And Keys

Every memory has an address made of two parts:

- the **namespace** says whose memory it is. It is a list of strings such as
  `["users", "ada", "memories"]`;
- the **key** says which memory it is inside that namespace, such as
  `"preferred_language"`.

A namespace and a key together identify exactly one item. `put/5` with the same
namespace and key replaces the item, and `get/3` and `delete/3` address it. The
same key under two namespaces is two unrelated items, so every user can have a
`"preferred_language"`:

```elixir
alias BeamWeaver.Memory

store = Memory.ETS.new()

{:ok, _item} =
  Memory.put(store, ["users", "ada", "memories"], "preferred_language", %{
    "content" => "Answers in German."
  })

{:ok, _item} =
  Memory.put(store, ["users", "bob", "memories"], "preferred_language", %{
    "content" => "Answers in French."
  })

{:ok, item} = Memory.get(store, ["users", "ada", "memories"], "preferred_language")
item.value
#=> %{"content" => "Answers in German."}

Memory.get(store, ["users", "carol", "memories"], "preferred_language")
#=> :error
```

### One Namespace Per Owner

Users, projects, teams, organizations, and agents are kept apart by giving each
of them a namespace of its own. Write a namespace like a path: the broadest
owner first, the narrowest owner after it, and the name of the collection last.

| The memory belongs to | Namespace | Shared by |
| --- | --- | --- |
| A user | `["users", user_id, "memories"]` | One user, in all of their conversations. |
| A project | `["projects", project_id, "memories"]` | Everybody who works on the project. |
| A user inside a project | `["projects", project_id, "users", user_id, "memories"]` | One user, only while working on that project. |
| An organization | `["orgs", org_id, "memories"]` | Every user and project of the organization. |
| An agent | `["agents", "support", "memories"]` | Every conversation of that agent, whoever the user is. |
| A user of one agent | `["agents", "support", "users", user_id, "memories"]` | One user, kept apart for each agent. |

A single conversation is not an owner in the store. What belongs to one
conversation is [short-term memory](short_term_memory.md), kept by the
checkpointer under the `thread_id`.

In a multi-tenant application put the tenant first, so that nothing of one
tenant shares a prefix with anything of another:

```elixir
["orgs", org_id, "memories"]
["orgs", org_id, "users", user_id, "memories"]
["orgs", org_id, "projects", project_id, "memories"]
["orgs", org_id, "projects", project_id, "users", user_id, "memories"]
```

Three rules keep this layout working:

1. **An owner's data is found by the namespace, never by the key.** Do not put
   the owner into the key (`"ada:preferred_language"`). `get/3` reads exactly
   one namespace, and a search under `["users", "ada"]` cannot return anything
   stored under `["users", "bob"]`.
2. **Order the parts by how you read.** `search/3`, `list_namespaces/2`, and
   `yield_keys/3` match a namespace *prefix*. With the owner first,
   `["orgs", "acme", "projects", "apollo"]` reaches everything that belongs to
   one project, and `["orgs", "acme"]` everything of the organization.
3. **End every namespace with a collection name.** `"memories"`, `"profile"`,
   or `"policies"` as the last part lets one owner have several collections,
   and it keeps an owner's own namespace from being a prefix of the namespaces
   of the owners below it.

The third rule prevents a leak that is easy to write:

```elixir
# The organization's rules are stored directly at the organization's path ...
{:ok, _item} = Memory.put(store, ["orgs", "acme"], "discounts", %{"content" => "At most 10%."})

# ... and the path of a user starts with the same parts.
{:ok, _item} = Memory.put(store, ["orgs", "acme", "users", "ada"], "salary", %{"content" => "Private."})

# Loading "the organization's rules" now returns the user's private memory too.
store |> Memory.search(["orgs", "acme"]) |> Enum.map(& &1.key)
#=> ["salary", "discounts"]
```

With `["orgs", "acme", "memories"]` and `["orgs", "acme", "users", "ada", "memories"]`
neither namespace is a prefix of the other, so each search returns only its own
items.

### Build Namespaces From The Run Context

The ids in a namespace decide whose data a tool reads and writes, so they must
come from your application and never from the model. Pass them as run
`context`, declare them in the agent's `context_schema`, and build every
namespace in one module:

```elixir
defmodule MyApp.Memory.Scope do
  @moduledoc "Builds the namespace of each memory scope from the run context."

  # Facts about one person, in every project of their organization.
  def namespace(:user, %{org_id: org_id, user_id: user_id}),
    do: ["orgs", org_id, "users", user_id, "memories"]

  # Facts about one project, shared by everyone who works on it.
  def namespace(:project, %{org_id: org_id, project_id: project_id}),
    do: ["orgs", org_id, "projects", project_id, "memories"]

  # Rules of the organization, shared by all of its users and projects.
  def namespace(:org, %{org_id: org_id}), do: ["orgs", org_id, "memories"]
end
```

```elixir
context_schema do
  field :org_id, :string, required: true
  field :project_id, :string, required: true
  field :user_id, :string, required: true
end
```

```elixir
MyApp.ProjectAssistant.invoke(
  %{messages: [BeamWeaver.Core.Message.user("What is the deadline?")]},
  context: %{org_id: "acme", project_id: "apollo", user_id: "ada"}
)
```

A run without a required id is refused before the model is called:

```elixir
MyApp.ProjectAssistant.invoke(
  %{messages: [BeamWeaver.Core.Message.user("What is the deadline?")]},
  context: %{org_id: "acme", user_id: "ada"}
)
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_context, details: %{field: :project_id}}}
```

Take the ids from the authenticated session or the record being worked on. Use
the keys exactly as the schema declares them: `%{user_id: "ada"}`, not
`%{"user_id" => "ada"}`.

{% hint style="warning" %}
**Namespace Rules**

A namespace cannot be empty, its parts cannot be empty or contain a dot, and it
cannot start with `"beam_weaver"`, which is reserved for internal bookkeeping.
Atoms and integers are converted with `to_string/1`, so a database id works as
it is. An email address or a domain name contains a dot and is rejected: use
the record's id instead. Keys have no such restrictions.
{% endhint %}

### Choose Keys

The key decides whether saving again replaces a memory or adds another one.

Use a **short, stable, meaningful key** for a fact that has one current value:
`"preferred_language"`, `"diet"`, `"deadline"`. Saving it again replaces the old
value, so the store never holds two contradicting versions. Ask for this in the
description of the tool that writes memories, because the model chooses the key.

Use a **generated key** for things that accumulate, such as notes or events:

```elixir
key = "note-" <> Integer.to_string(System.system_time(:millisecond))

{:ok, _item} =
  Memory.put(store, ["users", "ada", "notes"], key, %{"content" => "Asked about invoices."})
```

Accumulating collections grow without bound. Give such items a `ttl:` or prune
the namespace, as shown in [Batch And Maintenance](#batch-and-maintenance).

`put/5` replaces the whole value and the whole metadata, and keeps
`created_at`. To change one field, read the item, change the map, and put it
back with its metadata:

```elixir
{:ok, item} = Memory.get(store, ["users", "ada", "memories"], "preferred_language")

{:ok, _item} =
  Memory.put(store, item.namespace, item.key, Map.put(item.value, "confirmed", true),
    metadata: item.metadata
  )
```

### Read One Scope Or Everything Below A Prefix

`get/3` reads one item of one namespace. `search/3` returns the items of the
given namespace *and of every namespace that starts with it*, most recently
updated first:

```elixir
store = Memory.ETS.new()

put = fn namespace, key, content ->
  {:ok, _item} = Memory.put(store, namespace, key, %{"content" => content})
end

put.(["orgs", "acme", "memories"], "discounts", "At most 10%.")
put.(["orgs", "acme", "projects", "apollo", "memories"], "deadline", "Launch is on June 3.")
put.(["orgs", "acme", "projects", "apollo", "users", "ada", "memories"], "role", "Leads QA.")
put.(["orgs", "acme", "users", "ada", "memories"], "preferred_language", "Answers in German.")

keys = fn prefix -> store |> Memory.search(prefix, limit: 100) |> Enum.map(& &1.key) |> Enum.sort() end

# Exactly one scope: no other namespace starts with these parts.
keys.(["orgs", "acme", "users", "ada", "memories"])
#=> ["preferred_language"]

# Everything that belongs to one project, including what its users keep inside it.
keys.(["orgs", "acme", "projects", "apollo"])
#=> ["deadline", "role"]

# Everything of the organization.
keys.(["orgs", "acme"])
#=> ["deadline", "discounts", "preferred_language", "role"]
```

Every returned item carries its `namespace`, so the results of a prefix search
can be grouped by owner.

`search/3` returns 10 items unless you pass `limit:`. Pass the limit you mean,
and page with `offset:` when a scope can be large:

```elixir
Memory.search(store, ["orgs", "acme", "users", "ada", "memories"], limit: 50, offset: 50)
```

### Filter Inside A Scope

`filter:` compares fields of the value and, for fields the value does not have,
of the metadata. `query:` keeps the items whose value or metadata contains the
text, ignoring case. With the store filled above:

```elixir
namespace = ["orgs", "acme", "users", "ada", "memories"]

{:ok, _item} =
  Memory.put(store, namespace, "diet", %{"content" => "Vegetarian.", "confidence" => 0.9},
    metadata: %{"kind" => "preference", "source" => "conversation"}
  )

Memory.search(store, namespace, filter: %{"kind" => "preference"}, limit: 50)
Memory.search(store, namespace, filter: %{"confidence" => %{"$gte" => 0.8}}, limit: 50)
Memory.search(store, namespace, filter: %{"source" => %{"$in" => ["conversation", "import"]}})
Memory.search(store, namespace, query: "vegetarian")
```

The operators are `$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`, `$in`, and `$nin`.
A dotted path such as `"profile.city"` reaches into nested maps.

Put what describes the memory itself into the value, and what describes how it
got there (`"source"`, `"saved_by"`, `"kind"`) into the metadata.

### List The Owners That Have Memories

`list_namespaces/2` returns namespaces instead of items. `prefix:` and
`suffix:` select them, `"*"` matches any single part, and `max_depth:` cuts the
result to its first parts, which turns it into a list of owners. With the same
store:

```elixir
# The projects of one organization that have any memory.
Memory.list_namespaces(store, prefix: ["orgs", "acme", "projects"], max_depth: 4)
#=> [["orgs", "acme", "projects", "apollo"]]

# The projects in which one user keeps memories.
Memory.list_namespaces(store, prefix: ["orgs", "acme", "projects", "*", "users", "ada"])
#=> [["orgs", "acme", "projects", "apollo", "users", "ada", "memories"]]

# Every namespace of one user, wherever it is in the tree.
Memory.list_namespaces(store, suffix: ["users", "ada", "memories"])
#=> [
#=>   ["orgs", "acme", "projects", "apollo", "users", "ada", "memories"],
#=>   ["orgs", "acme", "users", "ada", "memories"]
#=> ]
```

It returns 100 namespaces unless you pass `limit:`, and accepts `offset:`.

### Delete One Memory Or Everything An Owner Has

```elixir
# One memory.
:ok = Memory.delete(store, ["orgs", "acme", "users", "ada", "memories"], "diet")

# Everything a project owns, in all namespaces below it.
for item <- Memory.search(store, ["orgs", "acme", "projects", "apollo"], limit: 10_000) do
  :ok = Memory.delete(store, item.namespace, item.key)
end
```

Delete by the `namespace` of each returned item, as above. `yield_keys/3`
returns the keys found below a prefix without their namespaces, so
`delete_many(store, namespace, Memory.yield_keys(store, namespace))` clears a
namespace only when no other namespace starts with it.

## Give An Agent Memory

An agent with long-term memory needs a store, tools that write and delete
records, and a prompt that loads what is already known. The code is the same
for `BeamWeaver.Memory.ETS` and `BeamWeaver.Memory.Ecto`.

### Memory Tools

A memory tool receives the store and the run context as injected arguments.
The model does not see them and cannot fill them in; it supplies only the key
and the text. Arguments from the model arrive under string keys
(`input["key"]`), injected arguments under atom keys (`input.store`,
`input.context`):

```elixir
defmodule MyApp.Memory.Save do
  use BeamWeaver.Tool

  name "save_memory"

  description "Remember one fact or preference about the user. Use a short stable key such as " <>
                "preferred_language. Saving under an existing key replaces that memory."

  injected :store, :store, type: :object
  injected :context, :context, type: :object

  schema do
    field :key, :string, required: true
    field :content, :string, required: true
  end

  @impl true
  def invoke(_tool, input, _opts) do
    namespace = ["users", input.context.user_id, "memories"]

    case BeamWeaver.Memory.put(input.store, namespace, input["key"], %{"content" => input["content"]}) do
      {:ok, item} -> {:ok, "Saved #{item.key}."}
      {:error, error} -> {:error, error}
    end
  end
end

defmodule MyApp.Memory.Search do
  use BeamWeaver.Tool

  name "search_memories"
  description "List what is remembered about the user, optionally only memories containing a word or phrase."

  injected :store, :store, type: :object
  injected :context, :context, type: :object

  schema do
    field :query, :string, required: false
  end

  @impl true
  def invoke(_tool, input, _opts) do
    namespace = ["users", input.context.user_id, "memories"]
    opts = if input["query"] in [nil, ""], do: [limit: 20], else: [query: input["query"], limit: 20]

    {:ok, input.store |> BeamWeaver.Memory.search(namespace, opts) |> Map.new(&{&1.key, &1.value["content"]})}
  end
end

defmodule MyApp.Memory.Delete do
  use BeamWeaver.Tool

  name "delete_memory"
  description "Forget one memory by its key."

  injected :store, :store, type: :object
  injected :context, :context, type: :object

  schema do
    field :key, :string, required: true
  end

  @impl true
  def invoke(_tool, input, _opts) do
    :ok = BeamWeaver.Memory.delete(input.store, ["users", input.context.user_id, "memories"], input["key"])
    {:ok, "Deleted #{input["key"]}."}
  end
end
```

There is no tool argument for the user: whatever the model asks for, the tools
work inside the namespace of the user the run belongs to.

### Load Memories Into The Prompt

What the agent already knows should not cost a tool call. A prompt function
receives the state and the runtime of the run, reads the store, and returns the
system prompt. `BeamWeaver.Agent.Middleware.DynamicPrompt` calls it before every
model call, so a memory saved in the middle of a run is part of the next model
call of the same run:

```elixir
defmodule MyApp.Memory.Prompt do
  alias BeamWeaver.Memory

  @instructions """
  You are a personal assistant. Save what the user tells you about themselves with save_memory, \
  one memory per fact, and remove a memory with delete_memory when they ask you to forget it.
  """

  def build(_state, runtime) do
    memories =
      runtime.store
      |> Memory.search(["users", runtime.context.user_id, "memories"], limit: 50)
      |> Enum.sort_by(& &1.key)
      |> Enum.map_join("\n", &"- #{&1.key}: #{&1.value["content"]}")

    @instructions <> "\nWhat you remember about this user:\n" <> if(memories == "", do: "(nothing yet)", else: memories)
  end
end
```

`DynamicPrompt` replaces the agent's `system_prompt`, so the instructions live
in the prompt function. Sorting by key keeps the prompt identical from run to
run while the memories do not change, which is what provider prompt caches
match on.

Load a whole scope this way while it is a few dozen short facts. When a scope
can grow large, load a part of it, for example
`filter: %{"kind" => "preference"}`, and let the agent look up the rest with
`search_memories`.

### The Agent

```elixir
defmodule MyApp.Assistant do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  store BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo)

  context_schema do
    field :user_id, :string, required: true
  end

  tools [MyApp.Memory.Save, MyApp.Memory.Search, MyApp.Memory.Delete]

  middleware do
    use BeamWeaver.Agent.Middleware.DynamicPrompt, prompt: &MyApp.Memory.Prompt.build/2
  end
end
```

Every run names its user. Two conversations of the same user share what was
saved, and another user starts with nothing:

```elixir
alias BeamWeaver.Core.Message

{:ok, _state} =
  MyApp.Assistant.invoke(
    %{messages: [Message.user("I'm vegetarian and I live in Lisbon. Please remember both.")]},
    context: %{user_id: "ada"}
  )

# A new conversation: the prompt already lists diet and city, no tool call is needed.
{:ok, _state} =
  MyApp.Assistant.invoke(%{messages: [Message.user("Suggest a dinner for tonight.")]},
    context: %{user_id: "ada"}
  )

# Another user: "What you remember about this user: (nothing yet)".
{:ok, _state} =
  MyApp.Assistant.invoke(%{messages: [Message.user("Suggest a dinner for tonight.")]},
    context: %{user_id: "bob"}
  )
```

The same agent built at runtime:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    name: "assistant",
    model: "openai:gpt-5.4",
    store: BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo),
    context_schema: %{user_id: %{type: :string, required: true}},
    tools: [MyApp.Memory.Save, MyApp.Memory.Search, MyApp.Memory.Delete],
    middleware: [{BeamWeaver.Agent.Middleware.DynamicPrompt, prompt: &MyApp.Memory.Prompt.build/2}]
  )

BeamWeaver.Agent.invoke(agent, %{messages: [Message.user("Hello")]}, context: %{user_id: "ada"})
```

### Work With The Same Records From Your Application

The memories are ordinary records, so a settings page, an import job, or an
account deletion works on them directly with the same namespace:

```elixir
alias BeamWeaver.Memory

store = Memory.Ecto.new(repo: MyApp.Repo)
namespace = ["users", user.id, "memories"]

# List what the assistant knows about the user.
memories = Memory.search(store, namespace, limit: 200)

# Correct one memory. The agent sees the new text in its next run.
{:ok, _item} =
  Memory.put(store, namespace, "city", %{"content" => "Lives in Porto."},
    metadata: %{"source" => "settings_page"}
  )

# Forget one memory.
:ok = Memory.delete(store, namespace, "diet")

# Forget everything about the user.
for item <- Memory.search(store, ["users", user.id], limit: 10_000) do
  :ok = Memory.delete(store, item.namespace, item.key)
end
```

### Several Scopes In One Agent

An agent that works for a user, inside a project, inside an organization reads
three scopes and may write two of them. The namespaces come from
`MyApp.Memory.Scope` in
[Build Namespaces From The Run Context](#build-namespaces-from-the-run-context).
The model chooses *which kind* of memory it saves; the ids still come from the
context:

```elixir
defmodule MyApp.Memory.SaveScoped do
  use BeamWeaver.Tool

  alias BeamWeaver.Memory
  alias MyApp.Memory.Scope

  name "save_memory"

  description "Remember one fact. Scope \"user\" is about the person you are talking to. Scope \"project\" is " <>
                "about the current project and is shared with everyone working on it. Saving under an " <>
                "existing key replaces that memory."

  injected :store, :store, type: :object
  injected :context, :context, type: :object

  schema do
    field :scope, :string, required: true, enum: ["user", "project"]
    field :key, :string, required: true
    field :content, :string, required: true
  end

  @impl true
  def invoke(_tool, input, _opts) do
    with {:ok, scope} <- writable_scope(input["scope"]),
         {:ok, item} <-
           Memory.put(input.store, Scope.namespace(scope, input.context), input["key"], %{"content" => input["content"]},
             metadata: %{"saved_by" => input.context.user_id}
           ) do
      {:ok, "Saved #{item.key} in #{input["scope"]} memory."}
    end
  end

  # The organization's memories are written by administrators, not by the agent.
  defp writable_scope("user"), do: {:ok, :user}
  defp writable_scope("project"), do: {:ok, :project}
  defp writable_scope(other), do: {:error, "unknown scope #{inspect(other)}"}
end
```

The prompt loads every scope the run may read, broadest first:

```elixir
defmodule MyApp.Memory.ScopedPrompt do
  alias BeamWeaver.Memory
  alias MyApp.Memory.Scope

  @sections [org: "Rules of the organization", project: "About this project", user: "About this user"]

  def build(_state, runtime) do
    sections =
      for {scope, title} <- @sections,
          items = Memory.search(runtime.store, Scope.namespace(scope, runtime.context), limit: 50),
          items != [] do
        lines = items |> Enum.sort_by(& &1.key) |> Enum.map_join("\n", &"- #{&1.key}: #{&1.value["content"]}")
        "## #{title}\n#{lines}"
      end

    Enum.join(["You are the project assistant." | sections], "\n\n")
  end
end
```

```elixir
defmodule MyApp.ProjectAssistant do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  store BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo)

  context_schema do
    field :org_id, :string, required: true
    field :project_id, :string, required: true
    field :user_id, :string, required: true
  end

  tools [MyApp.Memory.SaveScoped]

  middleware do
    use BeamWeaver.Agent.Middleware.DynamicPrompt, prompt: &MyApp.Memory.ScopedPrompt.build/2
  end
end
```

The agent has no tool that writes the organization's scope. An administrator
writes those rules from application code, with the same `Scope` module:

```elixir
alias BeamWeaver.Memory
alias MyApp.Memory.Scope

store = Memory.Ecto.new(repo: MyApp.Repo)

{:ok, _item} =
  Memory.put(store, Scope.namespace(:org, %{org_id: "acme"}), "discounts",
    %{"content" => "Never offer more than 10% discount."},
    metadata: %{"saved_by" => admin.id}
  )
```

After Ada saved her language with scope `"user"` and the launch date with scope
`"project"` while working on `apollo`, the prompts of three runs carry these
memory sections:

```text
context: %{org_id: "acme", project_id: "apollo", user_id: "ada"}

## Rules of the organization
- discounts: Never offer more than 10% discount.

## About this project
- deadline: Launch is on June 3.

## About this user
- language: Answers in German.
```

```text
context: %{org_id: "acme", project_id: "apollo", user_id: "bob"}

## Rules of the organization
- discounts: Never offer more than 10% discount.

## About this project
- deadline: Launch is on June 3.
```

```text
context: %{org_id: "acme", project_id: "zeus", user_id: "ada"}

## Rules of the organization
- discounts: Never offer more than 10% discount.

## About this user
- language: Answers in German.
```

A run for another organization sees none of it, even with the same project and
user ids, because every namespace starts with the organization.

More scopes follow the same three steps: a clause in `Scope`, the id in the
`context_schema`, a section in the prompt. A user who belongs to several teams
gets their `team_ids` in the context, declared as `field :team_ids, :list`, and
the prompt function loads one section for each of them.

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

`BeamWeaver.Memory.Ecto` stores JSONB records and supports namespace, filter,
query, TTL, and batch operations through the memory query layer. It does not
manage a pgvector semantic index. Use `BeamWeaver.Memory.ETS` for local
indexed-memory tests, or implement a custom `BeamWeaver.Memory.Store` adapter
for production vector memory.
{% endhint %}

## Read Long-Term Memory In Tools

Tools created at runtime with `Tool.from_function!/1` use the same injection as
the tool modules above: list `:store` and `:context` under `injected:`. The
model does not see injected fields. This tool reads one profile record kept in
the user's own namespace:

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Core.{Message, Tool}
alias BeamWeaver.Memory

store = Memory.ETS.new()

{:ok, _item} =
  Memory.put(store, ["users", "user_123", "profile"], "info", %{
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

      case Memory.get(store, ["users", user_id, "profile"], "info") do
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
        Memory.put(store, ["users", user_id, "profile"], "info", %{"name" => name},
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

{:ok, item} = Memory.get(store, ["users", "user_123", "profile"], "info")
```

{% hint style="info" %}
**Provider-Independent**

The store API does not depend on the model provider. The examples in this guide
run unchanged with any chat model BeamWeaver supports. See [Models](models.md).
{% endhint %}

## Batch And Maintenance

Use batch operations when you need to group reads and writes:

```elixir
alias BeamWeaver.Memory
alias BeamWeaver.Memory.{GetOp, ListNamespacesOp, MatchCondition, PutOp, SearchOp}

results =
  Memory.batch(store, [
    %PutOp{namespace: ["users", "user_123", "memories"], key: "style", value: %{"style" => "brief"}},
    %GetOp{namespace: ["users", "user_123", "memories"], key: "style"},
    %SearchOp{namespace: ["users"], filter: %{"style" => "brief"}},
    %ListNamespacesOp{match_conditions: [%MatchCondition{type: :prefix, path: ["users"]}]}
  ])
```

Stores also support TTL and retention where the adapter implements it. `ttl:`
is in minutes:

```elixir
{:ok, _item} =
  Memory.put(store, ["users", "user_123", "notes"], "temporary-note", %{"text" => "expires"}, ttl: 60)

{:ok, _expired_count} = Memory.sweep_expired(store)
{:ok, _pruned_count} = Memory.prune(store, namespace: ["users"], max_entries: 1_000)
```

Use `Memory.async_put/5`, `Memory.async_get/4`, `Memory.async_search/3`, and
other async helpers when memory work should run through BeamWeaver's task-backed
async boundary.
