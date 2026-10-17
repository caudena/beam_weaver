# Caching

A cache answers a repeated request with a stored result instead of doing the
work again. BeamWeaver caches the results of graph nodes and model calls in a
cache adapter you choose, and `prompt_caching true` turns on provider prompt
caching, which makes the stable start of a long prompt cheaper to send again.

## Cache a graph node

Give a node `cache:` and pass a cache adapter with the call. Here the
`classify` node asks a model for the ticket's category, and the second run
with the same subject gets the category from the cache:

```elixir
defmodule MyApp.TicketTriage do
  use BeamWeaver.Agent

  alias BeamWeaver.Core.{ChatModel, Message}
  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_node(:classify, &classify/1, cache: [ttl: :timer.hours(24)])
    |> Graph.add_node(:reply, &reply/1)
    |> Graph.add_edge(Graph.start(), :classify)
    |> Graph.add_edge(:classify, :reply)
    |> Graph.add_edge(:reply, Graph.end_node())
  end

  def classify(%{subject: subject}) do
    model = BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["billing"])
    {:ok, answer} = ChatModel.invoke(model, [Message.user("Classify this ticket: " <> subject)])
    %{category: Message.text(answer)}
  end

  def reply(%{category: category}), do: %{reply: "Routed to the #{category} queue."}
end

cache = BeamWeaver.Cache.ETS.new()
input = %{subject: "Refund for order A-1001"}

{:ok, _first} = MyApp.TicketTriage.invoke(input, cache: cache)
{:ok, events} = MyApp.TicketTriage.stream_events(input, cache: cache, live: true)

for %{event: %BeamWeaver.Stream.Events.Task{kind: :cache_hit, node: node}} <- events, do: node
#=> ["classify"]
```

The first run called the model and saved what `classify` returned. The second
run found that result, skipped the node, and reported a `:cache_hit` task event.
The `reply` node has no `cache:`, so it ran both times. Only a node that
returns is cached: one that fails or pauses runs again on the next call, and
so does one whose `error_handler:` supplied the result.

## Choose the cache key

By default the key is the graph, the node and the whole state the node
receives, so any change in the state is a different request. When the state
also carries data that doesn't affect the answer, such as when a ticket
arrived, key on what does:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

classify = fn %{subject: subject} -> %{category: if(subject =~ ~r/refund/i, do: "billing", else: "general")} end
by_subject = fn {_graph, _node, state} -> state.subject end

triage =
  Graph.new()
  |> Graph.add_node(:classify, classify, cache: [key: by_subject, namespace: :classify_v1])
  |> Graph.add_edge(Graph.start(), :classify)
  |> Graph.add_edge(:classify, Graph.end_node())
  |> Graph.compile!(cache: BeamWeaver.Cache.ETS.new())

{:ok, _first} = Compiled.invoke(triage, %{subject: "Refund for A-1001", received_at: 1})
{:ok, events} = Compiled.stream_events(triage, %{subject: "Refund for A-1001", received_at: 2}, live: true)

for %{event: %BeamWeaver.Stream.Events.Task{kind: :cache_hit, node: node}} <- events, do: node
#=> ["classify"]
```

`cache:` on a node takes `true` for the defaults, a keyword list, or a
`BeamWeaver.CachePolicy`:

| Option | Meaning | Default |
| --- | --- | --- |
| `ttl:` | How long an entry lives, in milliseconds from when the node ran; a hit doesn't extend it | forever |
| `key:` | A function of `{graph, node, state}`, or `{module, function, args}`, that returns the key | the whole tuple |
| `namespace:` | Keeps entries apart; change it to drop old results, for example when the prompt changes | `:default` |
| `metadata:` | A map stored with each entry | `%{}` |

Cache only nodes whose result depends on their input alone. A node that reads
the clock, a database or a random number would replay a stale answer.

## Where the cache lives

The adapter comes with the call, as `cache:` on `invoke/2` or
`stream_events/2`, or with `Graph.compile/2` for a compiled graph. A graph with
cached nodes and no adapter refuses to run:

```elixir
MyApp.TicketTriage.invoke(input)
#=> {:error, %BeamWeaver.Core.Error{type: :explicit_cache_required}}
```

`BeamWeaver.Cache.ETS` keeps entries in memory on one node; create it once,
like a checkpointer. `BeamWeaver.Cache.Ecto` keeps them in Postgres and is a
plain struct, so a graph module can declare it:

```elixir
defmodule MyApp.TicketTriage do
  use BeamWeaver.Agent

  alias BeamWeaver.Graph

  cache BeamWeaver.Cache.Ecto.new(repo: MyApp.Repo)

  def graph do
    Graph.new()
    |> Graph.add_node(:classify, &classify/1, cache: [ttl: :timer.hours(24)])
    |> Graph.add_edge(Graph.start(), :classify)
    |> Graph.add_edge(:classify, Graph.end_node())
  end

  def classify(_state), do: %{category: "billing"}
end
```

A `cache:` passed with a call replaces the declared one, which is how tests use
an ETS cache. Create the Postgres table with
`BeamWeaver.Migrations.up(adapters: [:cache])`; see [Storage](storage.md).

## Expiry and size

An entry with a `ttl:` is skipped once it expires and deleted when it is next
read. `BeamWeaver.Cache.sweep_expired/2` deletes all expired entries at once;
run it from a periodic job:

```elixir
orders = BeamWeaver.Cache.ETS.new()
:ok = BeamWeaver.Cache.put(orders, :status, "A-1001", "shipped", ttl: 10)
:ok = BeamWeaver.Cache.put(orders, :status, "A-1002", "shipped", ttl: 10)
Process.sleep(20)

BeamWeaver.Cache.sweep_expired(orders)
#=> {:ok, 2}
```

`BeamWeaver.Cache.ETS.new(max_entries: 10_000)` caps an ETS cache: each new
entry over the limit drops the oldest one.

`BeamWeaver.Cache.lookup/4`, `put/5`, `delete/4` and `clear/3` are the same
calls the graph makes, so your own code can cache with the same adapter. Every
lookup emits a `[:beam_weaver, :cache, :hit]` or `[:beam_weaver, :cache, :miss]`
telemetry event (see [Tracing](tracing.md#metrics-with-telemetry)).

## Cache model answers

`BeamWeaver.Models.cached/3` wraps a model so that the same messages and
options get the stored answer. Options such as `ttl:` apply to every entry. A
cached answer comes back with `total_cost` set to 0:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

model =
  BeamWeaver.Models.init_chat_model!("fake:chat",
    responses: ["Refunds reach your card in 5 to 7 business days."],
    usage_metadata: %{input_tokens: 42, output_tokens: 12, total_tokens: 54, total_cost: 0.0003}
  )

cached_model = BeamWeaver.Models.cached(model, BeamWeaver.Cache.ETS.new(), ttl: :timer.hours(1))
question = [Message.user("How long do refunds take?")]

{:ok, first} = ChatModel.invoke(cached_model, question)
{:ok, second} = ChatModel.invoke(cached_model, question)
{first.usage_metadata.total_cost, second.usage_metadata.total_cost}
#=> {0.0003, 0}
```

A cached model works anywhere a model does, including as an agent's `model`.

## Prompt caching

Providers can reuse the start of a request they have seen recently, usually
the system prompt and the tool definitions, and charge less for those tokens.
`prompt_caching true` adds the `BeamWeaver.Agent.Middleware.PromptCaching`
middleware, which sends what each provider needs:

| Provider | What `prompt_caching` sends |
| --- | --- |
| Anthropic | A `cache_control` marker on the system prompt |
| OpenAI, Moonshot | A `prompt_cache_key` that names the prompt |
| xAI | A `prompt_cache_key` and the `x-grok-conv-id` header; on Chat Completions only the header |
| Google, DeepSeek, Z.ai | Nothing: they cache repeated prefixes on their own |

```elixir
model "anthropic:claude-haiku-4-5"
system_prompt "You are Acme's support agent. Follow the refund policy below. ..."
prompt_caching true
```

The cache key comes from a scope (the agent's name by default), the model and
the system prompt. `prompt_caching scope: "support", version: "v2"` sets them
yourself; change `version:` to start fresh. A cache only helps while the start
of the prompt stays the same, so keep per-user data such as names and dates
out of the system prompt and put it in the messages. The provider pages cover
each provider's options and limits; for example
[Anthropic](providers/anthropic.md) and [OpenAI](providers/openai.md).

## Check prompt cache hits

Providers report cached input tokens in the answer's usage, and BeamWeaver
puts them under `input_token_details.cache_read` whichever provider sent them.
The fake model below is scripted to report what a provider would send:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat",
    responses: ["Order A-1001 shipped on Monday."],
    usage_metadata: %{input_tokens: 2_140, output_tokens: 9, input_token_details: %{cache_read: 2_048}}

  system_prompt "You are Acme's support agent."
  prompt_caching true
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]})
answer = List.last(result.messages)
get_in(answer.usage_metadata, [:input_token_details, :cache_read])
#=> 2048
```

A first call usually reports no `cache_read`, and later calls within the
provider's cache lifetime report most of the prompt. Traces record the same
usage for every model call (see [Tracing](tracing.md)).

## Reference

- [`BeamWeaver.Cache`](https://hexdocs.pm/beam_weaver/BeamWeaver.Cache.html): the cache contract and functions
- [`BeamWeaver.CachePolicy`](https://hexdocs.pm/beam_weaver/BeamWeaver.CachePolicy.html): key, namespace and lifetime of node cache entries
- [`BeamWeaver.Cache.ETS`](https://hexdocs.pm/beam_weaver/BeamWeaver.Cache.ETS.html): in-memory cache
- [`BeamWeaver.Cache.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Cache.Ecto.html): Postgres cache
- [`BeamWeaver.Models`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.html): `cached/3`
- [`BeamWeaver.Agent.Middleware.PromptCaching`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.PromptCaching.html): provider prompt caching for agents
- [`BeamWeaver.PromptCache`](https://hexdocs.pm/beam_weaver/BeamWeaver.PromptCache.html): stable prompt cache keys
