# Rate Limiting

Rate limiting controls admission to a provider or service before work starts.
BeamWeaver's token bucket is an in-memory process. It can delay a burst or
reject excess work; it is not a distributed account-wide quota service.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Wrap a real model

After [Installation](installation.md), create a bucket once and reuse it with
the model. This call consumes one token and actually contacts OpenAI:

```elixir
alias BeamWeaver.RateLimiter
{:ok, limiter} = RateLimiter.start_bucket(capacity: 2, initial_tokens: 2, refill_interval: 60_000)

try do
  model =
    BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)
    |> BeamWeaver.Models.with_rate_limiter(limiter: limiter)

  {:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Explain rate limiting in one sentence.")
  true = byte_size(BeamWeaver.Core.Message.text(reply)) > 0
  %{tokens: 1} = RateLimiter.snapshot(limiter)
  :ok = RateLimiter.acquire(limiter)
  {:error, error} = RateLimiter.acquire(limiter, 1, mode: :reject)
  :rate_limited = error.type
after
  DynamicSupervisor.terminate_child(BeamWeaver.RateLimiter.Supervisor, limiter)
end
```

`start_bucket/1` starts a permanent child under BeamWeaver’s rate-limiter
supervisor. Stop a temporary bucket with `DynamicSupervisor.terminate_child/2`,
as above; stopping its GenServer alone makes the supervisor restart it.

The wrapped model works for direct calls and as an agent's model. Keep the
limiter alive for the workload it governs; creating a fresh bucket per request
would reset the budget.

## Take tokens from a bucket

| Option | Meaning | Default |
| --- | --- | --- |
| `capacity:` | Maximum stored tokens/burst | 1 |
| `refill_amount:` | Tokens added per refill | Capacity |
| `refill_interval:` | Refill period in milliseconds | 1,000 |
| `initial_tokens:` | Available tokens at startup | 0 |
| `name:` | Registered process name | None |

Acquire one token per request or an explicit amount for weighted work. This
is a token-bucket rate, not a strict rolling-minute counter. A full bucket can
permit an immediate burst, followed by later refill allowance.

Acquire weighted tokens and inspect the remaining capacity. This local example needs no provider:

```elixir
alias BeamWeaver.RateLimiter
{:ok, bucket} = RateLimiter.start_bucket(capacity: 3, initial_tokens: 3, refill_interval: 60_000)

try do
  :ok = RateLimiter.acquire(bucket, 2)
  %{tokens: 1} = RateLimiter.snapshot(bucket)
  {:error, %{type: :amount_exceeds_capacity}} = RateLimiter.acquire(bucket, 4, mode: :reject)
  :ok
after
  DynamicSupervisor.terminate_child(BeamWeaver.RateLimiter.Supervisor, bucket)
end
```

## When a call is limited

`mode: :wait` queues until tokens are available or the timeout expires
(default 5,000 ms). `mode: :reject` returns `:rate_limited` immediately.
An amount larger than capacity returns `:amount_exceeds_capacity`.

Waiting callers leave the queue if they exit. A smaller new request that fits
available tokens can proceed while a larger request waits; do not assume
strict fairness across different weights. `snapshot/1` reports token and queue
counts for diagnosis.

An empty bucket can reject immediately or wait until a deadline:

```elixir
{:ok, bucket} = BeamWeaver.RateLimiter.start_bucket(capacity: 1, initial_tokens: 0, refill_interval: 60_000)

try do
  {:error, %{type: :rate_limited}} = BeamWeaver.RateLimiter.acquire(bucket, 1, mode: :reject)
  {:error, limited} = BeamWeaver.RateLimiter.acquire(bucket, 1, timeout: 20)
  IO.inspect(limited.type, label: "Waiting deadline result")
  %{queued: 0} = BeamWeaver.RateLimiter.snapshot(bucket)
after
  DynamicSupervisor.terminate_child(BeamWeaver.RateLimiter.Supervisor, bucket)
end
```

## Limit model calls in an agent

Use the wrapped model, or a `wrap_model_call/3` hook that acquires before
calling its handler. If retry middleware wraps admission, every retried attempt
must acquire again. Give retries an actual delay so they do not immediately
hit the same empty bucket. Account for time spent waiting in the whole-run
budget, in addition to provider timeout.

A wrapper admits each provider attempt through the shared named limiter:

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

  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
  system_prompt "You are Acme's support agent."
  middleware [{MyApp.ModelRateLimit, timeout: 20}]
end

{:ok, bucket} =
  RateLimiter.start_bucket(name: MyApp.ModelLimiter, capacity: 1, initial_tokens: 1, refill_interval: :timer.minutes(1))

{:ok, _result} = MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]})
{:error, %BeamWeaver.Core.Error{type: :rate_limited}} = MyApp.SupportAgent.invoke(%{messages: ["And order A-1002?"]})
DynamicSupervisor.terminate_child(BeamWeaver.RateLimiter.Supervisor, bucket)
```

## Limit a tool

A tool can acquire from its service's bucket before making an external call.
Return a meaningful error when admission fails so the model can explain or
choose another action. Admission is not a reservation that rolls back an
already-completed side effect. Keep mutating tool retries idempotent.

A tool can guard its own service independently of model admission:

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

Start the tool’s limiter and execute the local help-center lookup:

```elixir
{:ok, bucket} =
  BeamWeaver.RateLimiter.start_bucket(
    name: MyApp.HelpCenterLimiter,
    capacity: 1,
    initial_tokens: 1,
    refill_interval: 60_000
  )

try do
  {:ok, text} = BeamWeaver.Core.Tool.invoke(MyApp.Tools.SearchHelpCenter, %{"query" => "refund"})
  true = text =~ "5 to 7 business days"
  %{tokens: 0} = BeamWeaver.RateLimiter.snapshot(bucket)
after
  DynamicSupervisor.terminate_child(BeamWeaver.RateLimiter.Supervisor, bucket)
end
```

## Run buckets in production

Supervise named `RateLimiter.TokenBucket` children. Distinct names give them
distinct child IDs. On restart, initial token settings apply again; choose
whether an immediate burst is appropriate.

Provider quotas can differ by account, model, request count and token volume.
Separate buckets accordingly. For token-based budgets, acquire a conservative
estimated amount and understand that estimates are not provider accounting.
With multiple application nodes, allocate quotas per node or implement a
shared limiter. `Models.with_rate_limiter/2` can use a custom adapter exposing
`acquire/3` through its policy.

Add these children to your application supervisor. The standalone version below starts and stops a temporary supervisor:

```elixir
children = [
  {BeamWeaver.RateLimiter.TokenBucket, name: MyApp.ModelLimiter, capacity: 50, refill_interval: 1_000},
  {BeamWeaver.RateLimiter.TokenBucket, name: MyApp.HelpCenterLimiter, capacity: 5, refill_interval: 1_000}
]

{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

try do
  true = is_pid(Process.whereis(MyApp.ModelLimiter))
  true = is_pid(Process.whereis(MyApp.HelpCenterLimiter))
after
  Supervisor.stop(supervisor)
end
```

## Wrap a model

`Models.with_rate_limiter/2` takes a limiter/policy and preserves the wrapped
model interface, including supported decision-model operations. A per-call
`rate_limiter:` can override the policy's limiter. Missing or invalid limiter
configuration is an explicit error, not unlimited operation.
