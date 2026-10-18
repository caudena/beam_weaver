# Caching

There are three distinct caches: graph-node results, complete model answers
and provider prompt prefixes. The first two can skip work; provider prefix
caching still makes a model request. Choose keys and invalidation based on
what affects the result.

Complete [Installation](installation.md) for the OpenAI examples below.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Cache a graph node

```elixir
defmodule MyApp.CachedClassifier do
  use BeamWeaver.Graph
  alias BeamWeaver.Core.{ChatModel, Message}

  graph do
    node :classify, &__MODULE__.classify/1, cache: [ttl: 60_000]
    edge start(), :classify
    edge :classify, finish()
  end

  def classify(%{subject: subject}) do
    model = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)

    with {:ok, reply} <-
           ChatModel.invoke(model, "Classify as billing or shipping. Reply only with that word. Ticket: #{subject}") do
      %{category: reply |> Message.text() |> String.trim() |> String.downcase()}
    end
  end
end

cache = BeamWeaver.Cache.ETS.new()
input = %{subject: "I was charged twice for order A-1001."}
{:ok, first} = MyApp.CachedClassifier.invoke(input, cache: cache)
"billing" = first.category
{:ok, stream} = MyApp.CachedClassifier.stream_events(input, cache: cache, live: true)
events = Enum.to_list(stream)
true = Enum.any?(events, &match?(%{event: %BeamWeaver.Stream.Events.Task{kind: :cache_hit, node: "classify"}}, &1))
false = Enum.any?(events, &match?(%{event: %BeamWeaver.Stream.Events.Error{}}, &1))
```

The first call uses the provider; the second reports an actual node cache hit.
Only successful normal node results are cached. Failure, interruption and
error-handler recovery do not become normal cached node results.

## Choose the cache key

The default key includes graph, node and input state. A custom `key:` receives
`{graph, node, state}`; `namespace:` separates versions of your policy or prompt.
`ttl:` is milliseconds and a hit does not extend it. Metadata can accompany
an entry.

Include every dependency that affects the answer: tenant, source revision,
model/prompt version and relevant configuration. If the node reads mutable
external state absent from the key, a cache can return stale or cross-tenant
data. Do not cache side-effecting actions as a substitute for idempotency.

This key varies with the tenant and source revision, while ignoring an unrelated UI field:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled
cache = BeamWeaver.Cache.ETS.new()

graph =
  Graph.new()
  |> Graph.add_node(:quote, fn %{tenant: tenant} -> %{quote: "Quote for #{tenant}"} end,
    cache: [namespace: "quote-v1", key: fn {_graph, _node, state} -> {state.tenant, state.revision} end]
  )
  |> Graph.add_edge(Graph.start(), :quote)
  |> Graph.add_edge(:quote, Graph.end_node())
  |> Graph.compile!(cache: cache)

{:ok, %{quote: "Quote for acme"}} = Compiled.invoke(graph, %{tenant: "acme", revision: 1, ui: "compact"})
{:ok, events} = Compiled.stream_events(graph, %{tenant: "acme", revision: 1, ui: "wide"})
true = Enum.any?(events, &match?(%{event: %BeamWeaver.Stream.Events.Task{kind: :cache_hit}}, &1))
```

## Where the cache lives

Provide an explicit cache adapter per module invocation or when compiling a
graph. Cached nodes without one fail with `:explicit_cache_required`.
ETS belongs to its creating process; Ecto uses PostgreSQL and the cache
migration in [Storage](storage.md). Call options can override declared adapters.

## Cache model answers

`Models.cached/3` reuses a full answer for the same model inputs/options:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}
model = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)
cached = BeamWeaver.Models.cached(model, BeamWeaver.Cache.ETS.new(), ttl: 60_000)
{:ok, original} = ChatModel.invoke(cached, "Define a parcel briefly.")
{:ok, replayed} = ChatModel.invoke(cached, "Define a parcel briefly.")
true = byte_size(Message.text(original)) > 0
true = Message.text(replayed) == Message.text(original)
0 = replayed.usage_metadata.total_cost
```

A cached response reports zero new cost; its retained token counts describe
the stored answer, not fresh provider consumption. Cache replay streaming is
not a second live provider stream. Use this wrapper only when reuse is correct
for the request's freshness and ownership requirements.

## Expiry and size

Cache `ttl:` is in milliseconds. The bulk `Cache.set_many/3` convenience
accepts `{value, ttl_seconds}` pairs and converts those seconds to milliseconds. Expired entries are missed and can be swept with
`Cache.sweep_expired/2`. ETS `max_entries:` bounds growth; cleanup and pruning
capabilities depend on the adapter. `lookup`, `put`, `delete` and `clear` also
support direct application caching. Check hit/miss telemetry when diagnosing
unexpected work or stale results.

Exercise TTL and capacity operations directly:

```elixir
orders = BeamWeaver.Cache.ETS.new()
:ok = BeamWeaver.Cache.put(orders, :status, "A-1001", "shipped", ttl: 10)
:ok = BeamWeaver.Cache.put(orders, :status, "A-1002", "shipped", ttl: 10)
Process.sleep(20)

BeamWeaver.Cache.sweep_expired(orders)
#=> {:ok, 2}
```

## Prompt caching

Provider caching reuses eligible prefixes while generating a new response.
The `prompt_caching` declaration configures supported provider hints:

| Provider | Integration behavior |
| --- | --- |
| Anthropic | Cache-control marker on instructions |
| OpenAI, Moonshot | Prompt cache key |
| xAI | Prompt cache key/conversation header as supported by the endpoint |
| Google, DeepSeek, Z.ai | Automatic prefix caching; no marker added by this middleware |

Google also exposes explicit cached-content resources; its provider guide
shows creation, use and deletion. Caching requirements and account behavior
remain provider-specific. A declaration does not guarantee a hit.

Keys include scope, model and prompt; `scope:` and `version:` customize
invalidation. Keep stable content before changing per-request content. Avoid
moving trusted instructions into untrusted user text merely to improve a hit rate.

## Check prompt cache hits

Read `usage_metadata.input_token_details.cache_read` from real replies.
A zero/missing value is not a verified hit. Do not test caching by inventing
usage metadata or by initializing a model without calling it.

Hits can depend on prefix length, expiry and provider routing.

Make two real calls with the same substantial prefix and report the provider’s measured cache reads. Zero means no hit was observed in that call:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

model =
  BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini",
    max_tokens: 128,
    timeout: 60_000,
    prompt_cache_key: "beamweaver-refund-guide-v1"
  )

prefix =
  "Answer briefly from the following policy.\n" <>
    String.duplicate("Refunds take five business days. Do not promise same-day refunds.\n", 160)

usage =
  for _ <- 1..2 do
    {:ok, reply} = ChatModel.invoke(model, [Message.system(prefix), Message.user("How long do refunds take?")])
    true = byte_size(Message.text(reply)) > 0
    get_in(reply.usage_metadata, [:input_token_details, :cache_read]) || 0
  end

IO.inspect(usage, label: "Observed cached input tokens per call")
```
