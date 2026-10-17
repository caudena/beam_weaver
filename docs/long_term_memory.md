# Long-Term Memory

A memory store keeps records, such as a customer's preferences, that outlive
any single conversation. Use it when an agent should remember facts about a
person, a team or an account in every thread, not only in the current one.

```elixir
alias BeamWeaver.Memory

store = Memory.ETS.new()
namespace = ["customers", "ada", "preferences"]

{:ok, _item} = Memory.put(store, namespace, "contact_channel", %{"value" => "email"})
{:ok, item} = Memory.get(store, namespace, "contact_channel")
item.value
#=> %{"value" => "email"}
```

A record lives under a namespace, which says whose memory it is, and a key,
which says which memory it is. Agents read and write records through tools
you give them, and your application uses the same functions.

## Create a store

`BeamWeaver.Memory.ETS` keeps records in memory on one node, which suits
development and tests. Create it once, for example in your supervision tree,
and pass it to every call with `store:`, the way you pass a checkpointer. An
agent module can't declare an ETS store: its declarations are evaluated on
every call, so `store BeamWeaver.Memory.ETS.new()` would give each call a new,
empty store, and the module doesn't compile.

In production, keep records in Postgres with `BeamWeaver.Memory.Ecto`. Its
store is a plain struct, so you can build it per call or declare it in the
agent module; a `store:` passed with a call replaces the declared one, which
is how tests swap in an ETS store:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini"
  store BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo)
end
```

[Storage](storage.md) shows the migration that creates the table.

## Records

`BeamWeaver.Memory.put/5` writes a record and returns it as a
`BeamWeaver.Memory.Item`.
Putting the same namespace and key again replaces the value and the metadata.
The value can be any map; keep it JSON-friendly (string keys, plain values)
so it stores the same way in Postgres. `metadata:` holds facts about the
record, such as where it came from:

```elixir
{:ok, item} =
  Memory.put(store, namespace, "language", %{"value" => "Portuguese"},
    metadata: %{"source" => "profile_form"}
  )

{item.namespace, item.key, item.metadata}
#=> {["customers", "ada", "preferences"], "language", %{"source" => "profile_form"}}
```

`BeamWeaver.Memory.get/3` returns `:error` for a missing record, and
`BeamWeaver.Memory.delete/3` returns `:ok` whether or not the record existed:

```elixir
:ok = Memory.delete(store, namespace, "language")
Memory.get(store, namespace, "language")
#=> :error
```

A namespace is a list of strings; atoms and integers are converted, so a
database id works as it is. Its parts can't be empty or contain a dot, so
use a customer's id rather than their email address:

```elixir
Memory.put(store, ["customers", "ada@example.com"], "language", %{"value" => "Portuguese"})
#=> {:error, {:invalid_namespace, "namespace parts cannot contain dots"}}
```

`BeamWeaver.Memory.search/3` and `BeamWeaver.Memory.list_namespaces/2`
return the same error for such a prefix.

`BeamWeaver.Memory.put_many/4`, `BeamWeaver.Memory.get_many/3` and
`BeamWeaver.Memory.delete_many/3` work on several keys of one namespace at
once, and `BeamWeaver.Memory.batch/2` runs a list of operations, checking
every namespace before it runs any.

## Give the agent memory tools

A memory tool gets the store and the call's context injected. The model never
sees injected arguments, so it supplies only the key and the value, and the
customer comes from your application:

```elixir
defmodule MyApp.Tools.SavePreference do
  use BeamWeaver.Tool

  alias BeamWeaver.Memory

  name "save_preference"

  description "Remember a lasting preference of the current customer. Saving an existing key replaces it."

  injected :store, :store
  injected :context, :context

  schema do
    field :key, :string, description: "A short, stable name, such as contact_channel"
    field :value, :string, description: "The preference, such as email"
  end

  @impl true
  def invoke(_tool, %{"key" => key, "value" => value} = input, _opts) do
    namespace = ["customers", input.context.customer_id, "preferences"]

    with {:ok, _item} <- Memory.put(input.store, namespace, key, %{"value" => value}) do
      {:ok, "Saved #{key}."}
    end
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("save_preference", %{"key" => "contact_channel", "value" => "phone"}),
      "Got it, we'll call you from now on."
    ]

  system_prompt "You are Acme's support agent. Save lasting customer preferences with save_preference."
  tools [MyApp.Tools.SavePreference]

  context_schema do
    field :customer_id, :string, required: true
  end
end

{:ok, _result} =
  MyApp.SupportAgent.invoke(%{messages: ["Please call me instead of emailing."]},
    store: store,
    context: %{customer_id: "ada"}
  )

{:ok, item} = Memory.get(store, ["customers", "ada", "preferences"], "contact_channel")
item.value
#=> %{"value" => "phone"}
```

This call had no checkpointer, so the conversation is gone, but the
preference stays in the store for every later conversation with Ada. The
tool's description tells the model to reuse stable keys, so a changed
preference replaces the old one instead of piling up next to it. A tool that
reads memory, such as `search_preferences`, follows the same pattern with
`BeamWeaver.Memory.search/3`.

## Load memories into the prompt

What the agent already knows shouldn't cost a tool call. Build the system
prompt from the store in a plain function, which is easy to test:

```elixir
defmodule MyApp.CustomerMemory do
  alias BeamWeaver.Memory

  def prompt(store, customer_id) do
    known =
      store
      |> Memory.search(["customers", customer_id, "preferences"], limit: 50)
      |> Enum.sort_by(& &1.key)
      |> Enum.map_join("\n", &"- #{&1.key}: #{&1.value["value"]}")

    "You are Acme's support agent. Known preferences of this customer:\n" <> known
  end
end

MyApp.CustomerMemory.prompt(store, "ada")
#=> "You are Acme's support agent. Known preferences of this customer:\n- contact_channel: phone"
```

Then let `BeamWeaver.Agent.Middleware.DynamicPrompt` call it before every
model call. A two-argument prompt function receives the state and the
runtime, which carries the call's `store` and `context`:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["We'll call you about order A-1001 today."]
  tools [MyApp.Tools.SavePreference]

  context_schema do
    field :customer_id, :string, required: true
  end

  middleware [
    {BeamWeaver.Agent.Middleware.DynamicPrompt,
     prompt: fn _state, runtime ->
       MyApp.CustomerMemory.prompt(runtime.store, runtime.context.customer_id)
     end}
  ]
end

{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["Any news on order A-1001?"]},
    store: store,
    context: %{customer_id: "ada"}
  )

result.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "We'll call you about order A-1001 today."
```

The prompt function replaces the whole system prompt: the agent's
`system_prompt` and the sections that declarations such as `filesystem` and
`memory` add, so keep all instructions in it. A preference saved during a run
shows up from the next model call on. Sorting by key keeps the prompt
identical while nothing changes, which helps provider prompt caches. Load a
whole namespace this way while it holds a few dozen short facts; when it can
grow large, load only part of it and give the agent a search tool for the
rest.

## Scope memory per customer

The ids in a namespace decide whose memory a tool touches, so take them from
your application, never from the model. The tools above read the customer
from `context:`, and `context_schema` refuses a call that doesn't say who the
customer is:

```elixir
MyApp.SupportAgent.invoke(%{messages: ["Hi!"]}, store: store)
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_context, details: %{field: :customer_id}}}
```

Pass the context with atom keys, as the schema declares them. Then lay
namespaces out like paths, owner first, and end each one with the name of the
collection. Searches match a namespace prefix, so a namespace that ends with
an owner also matches everything stored below it:

```elixir
accounts = Memory.ETS.new()

{:ok, _} = Memory.put(accounts, ["accounts", "acme"], "billing_contact", %{"value" => "finance team"})
{:ok, _} = Memory.put(accounts, ["accounts", "acme", "users", "ada"], "contact_channel", %{"value" => "phone"})

# Reading the account's memory also returns Ada's private record.
accounts |> Memory.search(["accounts", "acme"]) |> Enum.map(& &1.key) |> Enum.sort()
#=> ["billing_contact", "contact_channel"]
```

With `["accounts", "acme", "memories"]` and
`["accounts", "acme", "users", "ada", "memories"]`, neither namespace is a
prefix of the other, and each search returns only its own records. Build every
namespace in one module of your application so tools, prompts and
maintenance code agree on the layout.

## Search

`BeamWeaver.Memory.search/3` returns the records of a namespace and of every
namespace below it, most recently updated first; `[]` searches them all:

| Option | Effect |
| --- | --- |
| `query:` | Keeps records whose value or metadata contains the text, ignoring case. |
| `filter:` | Matches fields of the value, then of the metadata: `%{"source" => "profile_form"}`. Operators: `$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`, `$in`, `$nin`. A dotted key such as `"address.city"` reaches into nested maps. |
| `limit:` | At most this many records; the default is 10. |
| `offset:` | Skips records, for paging. |

```elixir
{:ok, _} =
  Memory.put(store, namespace, "language", %{"value" => "Portuguese"},
    metadata: %{"source" => "profile_form"}
  )

store |> Memory.search(namespace, query: "portu") |> Enum.map(& &1.key)
#=> ["language"]

store |> Memory.search(namespace, filter: %{"value" => %{"$in" => ["phone", "sms"]}}) |> Enum.map(& &1.key)
#=> ["contact_channel"]
```

`BeamWeaver.Memory.list_namespaces/2` lists namespaces instead of records.
`prefix:` and `suffix:` select them, `"*"` matches any one part, and
`max_depth:` shortens the results, which turns them into a list of owners:

```elixir
Memory.list_namespaces(store, prefix: ["customers"], max_depth: 2)
#=> [["customers", "ada"]]
```

## Semantic search

To search by meaning, give `Memory.ETS` an embedding model and the fields of
the value to index. `query:` then ranks records by similarity, and each result
is a `BeamWeaver.Memory.SearchItem` with a `score`:

```elixir
embeddings = BeamWeaver.Models.init_embeddings!("fake:embedding")
notes = Memory.ETS.new(index: [embed: embeddings, fields: ["text"]])
ada_notes = ["customers", "ada", "notes"]

{:ok, _} = Memory.put(notes, ada_notes, "allergy", %{"text" => "Allergic to peanuts."})
{:ok, _} = Memory.put(notes, ada_notes, "address", %{"text" => "Moved to Lisbon in May."})

results = Memory.search(notes, ada_notes, query: "Where does Ada live?", limit: 2)
results |> Enum.map(& &1.key) |> Enum.sort()
#=> ["address", "allergy"]
```

The fake embedding model gives arbitrary scores, so the order here means
nothing; use a real model such as
`BeamWeaver.Models.init_embeddings!("openai:text-embedding-3-small")` in your
application. Pass `index: false` when you put a record that shouldn't be
indexed; such records come last in the results, without a score.
`Memory.Ecto` has no vector index: with it, `query:` is the plain text match
from [Search](#search).

## Expiry and cleanup

`ttl:` gives a record a lifetime in minutes. Once it has expired, `get`,
`search` and `list_namespaces` skip it:

```elixir
{:ok, item} = Memory.put(store, namespace, "promo_code", %{"value" => "SPRING10"}, ttl: 60 * 24 * 7)
{item.ttl, match?(%DateTime{}, item.expires_at)}
#=> {10080, true}
```

Both stores take the same two options. `default_ttl:` gives a lifetime to
every record put without `ttl:`, and `refresh_ttl: true` makes `get` and
`search` start a record's lifetime again, so the records the agent reads stay
and the others expire. Without it, reading a record leaves its expiry alone.
`refresh_ttl:` on a `BeamWeaver.Memory.GetOp` or `BeamWeaver.Memory.SearchOp`
overrides the store's setting for one read:

```elixir
recent = Memory.ETS.new(default_ttl: 60 * 24 * 30, refresh_ttl: true)

{:ok, item} = Memory.put(recent, ["customers", "ada", "notes"], "allergy", %{"text" => "Allergic to peanuts."})
item.ttl
#=> 43200
```

`BeamWeaver.Memory.sweep_expired/2` deletes expired records for good and
returns how many it removed. For Postgres, set a default lifetime and run the
sweeper under your supervision tree:

```elixir
store = BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo, default_ttl: 60 * 24 * 90)

children = [
  MyApp.Repo,
  %{
    id: :memory_sweeper,
    start: {BeamWeaver.Memory.Ecto, :start_ttl_sweeper, [store, [interval: :timer.minutes(10)]]}
  }
]
```

`BeamWeaver.Memory.prune/2` bounds collections that grow, such as notes, in
both stores. `max_entries:` keeps only the most recently updated records of
exactly the `namespace:`; `older_than:` (a `DateTime`) deletes the records
last updated before it, and `max_age_ms:` those older than that. It returns
how many records it deleted:

```elixir
contacts = ["customers", "ada", "contacts"]
log = Memory.ETS.new()
for n <- 1..5, do: {:ok, _item} = Memory.put(log, contacts, "contact_#{n}", %{"channel" => "email"})

Memory.prune(log, namespace: contacts, max_entries: 3)
#=> {:ok, 2}
```

## Edit memories from your application

Records are ordinary data, so a settings page, an import job or an account
deletion uses the same namespace as the agent:

```elixir
# Show what the agent remembers about Ada.
store |> Memory.search(["customers", "ada"], limit: 100) |> Enum.map(& &1.key) |> Enum.sort()
#=> ["contact_channel", "language", "promo_code"]
```

```elixir
# Correct one record; the agent sees the new value from its next model call.
{:ok, _} =
  Memory.put(store, namespace, "contact_channel", %{"value" => "sms"},
    metadata: %{"source" => "settings_page"}
  )

# Forget everything about Ada.
for item <- Memory.search(store, ["customers", "ada"], limit: 1_000) do
  :ok = Memory.delete(store, item.namespace, item.key)
end

Memory.search(store, ["customers", "ada"])
#=> []
```

## Choose where memory lives

| | Thread | Memory store | Memory files |
| --- | --- | --- | --- |
| Holds | One conversation's messages and state | Records under a namespace and a key | Markdown text |
| Kept by | The checkpointer | `Memory.ETS` or `Memory.Ecto` | The agent's filesystem |
| The model sees it | On every model call of the thread | Through your tools and prompt function | In the system prompt of every run |
| How it changes | Each turn adds messages | Through tools you write | With `edit_file` and `write_file` |
| Use it for | The current conversation | Many small facts per user that your app lists, edits or deletes | Instructions and notes that people also read and edit |

See [Short-Term Memory](short_term_memory.md) for threads and
[Memory Files](memory_files.md) for files.

## Reference

- [`BeamWeaver.Memory`](https://hexdocs.pm/beam_weaver/BeamWeaver.Memory.html): putting, reading, searching and deleting records
- [`BeamWeaver.Memory.ETS`](https://hexdocs.pm/beam_weaver/BeamWeaver.Memory.ETS.html): in-memory store with an optional embedding index
- [`BeamWeaver.Memory.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Memory.Ecto.html): Postgres store and TTL sweeper
- [`BeamWeaver.Memory.Item`](https://hexdocs.pm/beam_weaver/BeamWeaver.Memory.Item.html): a stored record
- [`BeamWeaver.Memory.SearchItem`](https://hexdocs.pm/beam_weaver/BeamWeaver.Memory.SearchItem.html): a semantic search result with its score
- [`BeamWeaver.Tool`](https://hexdocs.pm/beam_weaver/BeamWeaver.Tool.html): tools with injected `store` and `context`
- [`BeamWeaver.Agent.Middleware.DynamicPrompt`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.DynamicPrompt.html): building the system prompt per model call
