# Rate Limiting

A rate limiter caps how often your application calls a provider or another
outside API, so a burst of traffic waits its turn instead of failing with the
provider's rate-limit errors. `BeamWeaver.RateLimiter` is an in-memory token
bucket that you call before each request.

## Take tokens from a bucket

```elixir
alias BeamWeaver.RateLimiter

{:ok, limiter} = RateLimiter.start_bucket(capacity: 2, initial_tokens: 2, refill_interval: :timer.minutes(1))

:ok = RateLimiter.acquire(limiter)
:ok = RateLimiter.acquire(limiter)
RateLimiter.acquire(limiter, 1, mode: :reject)
#=> {:error, %BeamWeaver.RateLimiter.Error{type: :rate_limited}}
```

The bucket holds up to `capacity` tokens and gets `refill_amount` new ones
every `refill_interval`. Each call takes one token, or `amount` with
`acquire(limiter, amount)`. The third call found the bucket empty and was
turned away.

| Option | Meaning | Default |
| --- | --- | --- |
| `capacity:` | The most tokens the bucket holds, which is the largest burst | `1` |
| `refill_amount:` | Tokens added at each refill | the capacity |
| `refill_interval:` | Milliseconds between refills | `1000` |
| `initial_tokens:` | Tokens at start | `0` |
| `name:` | A registered name, to call the bucket from anywhere | none |

`capacity: 60, refill_interval: :timer.minutes(1)` allows 60 calls a minute,
all at once if they come at once. `capacity: 10, refill_amount: 1` allows one
call a second on average, with bursts of up to 10.

## When a call is limited

By default `acquire/3` waits in line until a refill brings enough tokens, for
up to `timeout:` milliseconds (5,000 by default), and then gives up:

```elixir
RateLimiter.acquire(limiter, 1, timeout: 20)
#=> {:error, %BeamWeaver.RateLimiter.Error{type: :timeout}}
```

| Mode | When the bucket is empty |
| --- | --- |
| `mode: :wait` (default) | Waits for a refill until `timeout:`; then `:timeout` |
| `mode: :reject` | Returns `:rate_limited` at once |

Waiting callers are served in the order they came, but a new call that fits
the tokens left is served at once, even while a larger request waits. A
caller that exits while it waits leaves the line, so it doesn't use up tokens.
Asking for more than `capacity` fails with `:amount_exceeds_capacity`.
`BeamWeaver.RateLimiter.snapshot/1` shows the tokens left and the callers
waiting:

```elixir
RateLimiter.snapshot(limiter)
#=> %{tokens: 0, queued: 0, capacity: 2}
```

## Limit model calls in an agent

A middleware takes a token before every model call. Start the bucket under a
name, so the middleware can find it:

```elixir
defmodule MyApp.ModelRateLimit do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Error
  alias BeamWeaver.RateLimiter

  defstruct limiter: MyApp.ModelLimiter, timeout: 5_000

  # Waits for a token before each model call, and fails the call if none comes in time.
  @impl true
  def wrap_model_call(%__MODULE__{} = middleware, request, handler) do
    case RateLimiter.acquire(middleware.limiter, 1, timeout: middleware.timeout) do
      :ok -> handler.(request)
      {:error, error} -> {:error, Error.new(:rate_limited, error.message)}
    end
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Order A-1001 shipped on Monday."]
  system_prompt "You are Acme's support agent."
  middleware [{MyApp.ModelRateLimit, timeout: 20}]
end

{:ok, _bucket} =
  RateLimiter.start_bucket(name: MyApp.ModelLimiter, capacity: 1, initial_tokens: 1, refill_interval: :timer.minutes(1))

{:ok, _result} = MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]})
MyApp.SupportAgent.invoke(%{messages: ["And order A-1002?"]})
#=> {:error, %BeamWeaver.Core.Error{type: :rate_limited}}
```

The first call took the only token; the second waited 20 milliseconds and
failed. The middleware works the same for streamed runs. `:rate_limited` counts
as a temporary error: list the `ModelRetry` middleware before this one and it
retries the call, as it retries a provider's own rate-limit errors (see
[Built-in Middleware](builtin_middleware.md)). Give `ModelRetry` an
`initial_delay:`, or its retries come at once and find the bucket still empty.

## Limit a tool

A tool that calls an outside API takes its token the same way. When it returns
an error, the model reads that the tool failed and can try again later or
answer without it:

```elixir
defmodule MyApp.Tools.SearchHelpCenter do
  use BeamWeaver.Tool

  alias BeamWeaver.Core.Error

  name "search_help_center"
  description "Search Acme's help center articles."

  schema do
    field :query, :string, description: "What to search for"
  end

  @impl true
  def invoke(_tool, %{"query" => query}, _opts) do
    case BeamWeaver.RateLimiter.acquire(MyApp.HelpCenterLimiter, 1, timeout: 2_000) do
      :ok -> {:ok, "Top article for #{query}: Refunds reach your card in 5 to 7 business days."}
      {:error, _limited} -> {:error, Error.new(:rate_limited, "The help center is busy; try again in a minute")}
    end
  end
end
```

## Run buckets in production

Start each bucket in your supervision tree, so it restarts with your
application. A bucket's child id is its `name:`, so several buckets can share
one supervisor:

```elixir
children = [
  {BeamWeaver.RateLimiter.TokenBucket, name: MyApp.ModelLimiter, capacity: 50, refill_interval: 1_000},
  {BeamWeaver.RateLimiter.TokenBucket, name: MyApp.HelpCenterLimiter, capacity: 5, refill_interval: 1_000}
]

Enum.map(children, &Supervisor.child_spec(&1, []).id)
#=> [MyApp.ModelLimiter, MyApp.HelpCenterLimiter]
```

Providers limit requests and tokens per minute, per API key and per model, and
their limits differ by account tier; their pages and your account settings
list yours. Use one bucket per key and model you call. A bucket counts calls,
not tokens: for a tokens-per-minute limit, size the bucket in thousands of
tokens and take `div(estimated_tokens, 1_000) + 1` per call. Buckets live on
one node, so with several nodes give each node its share of the limit.

## Wrap a model

`BeamWeaver.Models.with_rate_limiter/2` wraps a model so that every call takes
a token from a bucket first. Use the wrapped model directly or as an agent's
`model`:

```elixir
{:ok, model_limiter} = RateLimiter.start_bucket(capacity: 10, initial_tokens: 10)

model =
  "fake:chat"
  |> BeamWeaver.Models.init_chat_model!(responses: ["Order A-1001 shipped on Monday."])
  |> BeamWeaver.Models.with_rate_limiter(limiter: model_limiter)

{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Where is order A-1001?")
BeamWeaver.Core.Message.text(reply)
#=> "Order A-1001 shipped on Monday."
```

## Reference

- [`BeamWeaver.RateLimiter`](https://hexdocs.pm/beam_weaver/BeamWeaver.RateLimiter.html): starting buckets and taking tokens
- [`BeamWeaver.RateLimiter.TokenBucket`](https://hexdocs.pm/beam_weaver/BeamWeaver.RateLimiter.TokenBucket.html): the token bucket process and its options
- [`BeamWeaver.RateLimiter.Error`](https://hexdocs.pm/beam_weaver/BeamWeaver.RateLimiter.Error.html): `:rate_limited`, `:timeout` and other failures
- [`BeamWeaver.Agent.Middleware`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.html): `wrap_model_call/3` for limits around model calls
