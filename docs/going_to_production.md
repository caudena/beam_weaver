# Going to Production

A checklist for running BeamWeaver agents in a production Elixir application:
where storage lives, how secrets and the signed-in customer reach a run, and
how runs are bounded, observed, and resumed after a deploy. Each item is short
and links to the page with the details.

## A production call

A production call names the conversation, says who the customer is, labels
the trace, and bounds the run. With a scripted model it runs as is:

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of one of the customer's orders."

  injected :context, :context

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id} = input, _opts) do
    {:ok, "Order #{order_id} for #{input.context.customer_id} shipped on Monday."}
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday."
    ]

  system_prompt "You are Acme's support agent."
  tools [MyApp.Tools.LookupOrder]

  context_schema do
    field :customer_id, :string, required: true
  end
end

saver = BeamWeaver.Checkpoint.ETS.new()

{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]},
    checkpointer: saver,
    config: %{"configurable" => %{"thread_id" => "ticket-42"}},
    context: %{customer_id: "cus_ada"},
    trace: [user_id: "cus_ada", thread_id: "ticket-42", execution_mode: "support_chat"],
    run_timeout: 60_000,
    recursion_limit: 20
  )

result.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Your order A-1001 shipped on Monday."
```

| Option | Why |
| --- | --- |
| `checkpointer:` | Saves each step, so the thread survives a crash or a deploy |
| `config:` thread id | Picks the conversation: one thread per ticket or chat |
| `context:` | The signed-in customer, from your session, never from the model |
| `trace:` | Finds this run among the others in your traces |
| `run_timeout:`, `recursion_limit:` | Stop a run that takes too long or loops |

## Create storage once

In production the checkpointer and the memory store live in your Ecto repo.
Both are plain structs, so one module can build them for the whole app:

Before running the database examples on this page, set `DATABASE_URL` to
an empty PostgreSQL database reserved for examples, then run this setup in
the same IEx session. The verification command creates a disposable database.

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
end

{:ok, _repo} = MyApp.Repo.start_link(url: System.fetch_env!("DATABASE_URL"), pool_size: 2, log: false)

defmodule MyApp.CreateAgentTables do
  use Ecto.Migration

  def up, do: BeamWeaver.Migrations.up(adapters: [:checkpoint, :memory, :cache])
  def down, do: BeamWeaver.Migrations.down(adapters: [:cache, :memory, :checkpoint])
end

:ok = Ecto.Migrator.up(MyApp.Repo, 1, MyApp.CreateAgentTables, log: false)
```

```elixir
defmodule MyApp.AgentStorage do
  def checkpointer, do: BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)
  def store, do: BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo)
end
```

Create their tables with a migration (see
[Storage](storage.md#create-the-tables)). Keep ETS adapters for tests and
development: their tables belong to the process that created them, so create
them once in a long-lived process, and never in an agent's declarations.

## Supervision

BeamWeaver is an OTP application and starts its own processes: the HTTP
connection pools, the trace store and exporter queue, and the supervisor for
rate limiter buckets. When the node stops, the exporter queue uploads the
traces still queued. It starts no supervisor for your tasks: add the
processes your application needs, such as a `Task.Supervisor` for agent runs
(see [Run agents in the background](#run-agents-in-the-background)), to its
own tree:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Task.Supervisor, name: MyApp.AgentTasks},
      {BeamWeaver.RateLimiter.TokenBucket, name: MyApp.ModelLimiter, capacity: 50, refill_interval: 1_000},
      %{
        id: :memory_sweeper,
        start: {BeamWeaver.Memory.TTLSweeper, :start_link, [MyApp.AgentStorage.store(), [interval: :timer.minutes(10)]]}
      }
    ]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor) do
      BeamWeaver.Migrations.verify_migrated!(repo: MyApp.Repo, adapters: [:checkpoint, :memory])
      {:ok, pid}
    end
  end
end
```

## Secrets and configuration

Read provider keys and the WeaveScope key from the environment at runtime, in
`config/runtime.exs`, never at compile time:

```elixir
import Config

if config_env() == :prod do
  config :beam_weaver, :openai, api_key: System.fetch_env!("OPENAI_API_KEY")

  config :beam_weaver,
    weave_scope: [
      endpoint: "https://app.weavescope.com",
      api_key: System.get_env("WEAVESCOPE_API_KEY"),
      otp_app: :my_app
    ]
end
```

Keep credentials out of everything the model sees: messages, prompts, state
and tool arguments. A tool that calls an outside API reads its credentials
from your configuration. Traces redact values that look like keys, but they
record messages as they are (see [Tracing](tracing.md#redaction)). Code that
runs in a sandbox gets no secrets at all (see [Sandboxes](sandboxes.md)).

## Identity and tenancy

BeamWeaver has no user accounts: your application authenticates the request
and passes the customer in `context:`. Declare it with `context_schema`, so a
call without it fails (see [Runtime Context](runtime_context.md)).

- **Threads.** Derive thread ids from your records, such as the ticket id, and
  check that the signed-in customer owns the ticket before you load its thread.
  A thread id selects data; it doesn't grant access to it.
- **Memory.** Build memory namespaces from `context:`, owner first (see
  [Long-Term Memory](long_term_memory.md#scope-memory-per-customer)).
- **Files and tools.** Scope filesystems and tool queries to the customer in
  `context:`, not to ids the model supplies.

## Bound every run

| Limit | How | Details |
| --- | --- | --- |
| Run time | `run_timeout` and `step_timeout` in the agent or on a call, in milliseconds, which fail with `:run_timeout` and `:step_timeout`; `timeout:` on the model for each model call, and `tool_timeout` for each tool call | [Durable Execution](durable_execution.md) |
| Steps | `recursion_limit` in the agent or on a call; an agent with tools allows 9,999 steps unless you set it | [Agents](agents.md) |
| Model and tool calls | `ModelCallLimit` and `ToolCallLimit` middleware | [Guardrails](guardrails.md#limit-model-and-tool-calls) |
| Provider errors | `ModelRetry`, `ModelFallback` and `ToolRetry` middleware | [Built-in Middleware](builtin_middleware.md) |
| Request rate | A token bucket in front of model and API calls | [Rate Limiting](rate_limiting.md) |
| Prompt size | Summarization, offloading and overflow recovery | [Context Management](context_management.md) |
| Sensitive actions | `interrupt_on` for human approval | [Human-in-the-Loop](human_in_the_loop.md) |

## Observe

- Pass `trace:` with the user, thread and kind of work on every call, and
  export to WeaveScope (see [Tracing](tracing.md#export-to-weavescope)).
- Attach telemetry handlers for failed runs, timeouts, retries and exporter
  dead letters (see [Tracing](tracing.md#metrics-with-telemetry)).
- Watch token usage per model call in the traces, and keep prompt prefixes
  stable to get cache hits (see [Caching](caching.md#prompt-caching)).
- Bound the local trace store: it keeps the 10,000 runs that finished last in
  the node's memory. A node that exports can set
  `config :beam_weaver, tracing: [max_runs: 0]` to keep only the runs in
  progress (see [Tracing](tracing.md#read-a-trace)).

## Run agents in the background

A web request shouldn't wait minutes for an agent. Start the run under your
own `Task.Supervisor`, and stream its events to the page (see
[Streaming](streaming.md#push-tokens-to-a-liveview)):

```elixir
{:ok, _tasks} = Task.Supervisor.start_link(name: MyApp.AgentTasks)

task =
  Task.Supervisor.async_nolink(MyApp.AgentTasks, fn ->
    MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]},
      checkpointer: BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo),
      config: %{"configurable" => %{"thread_id" => "ticket-42"}},
      context: %{customer_id: "cus_ada"}
    )
  end)

# A LiveView receives the result as a {ref, result} message in handle_info/2;
# a background job can wait for completion:
{:ok, result} = Task.await(task, :timer.minutes(5))
true = is_list(result.messages)
```

Work that doesn't belong to a request, such as consolidating memories,
pruning old checkpoints (see [Checkpoints and Time Travel](checkpoints.md))
or sweeping expired cache entries, belongs in your job scheduler, such as
Oban.

## Deploys and resuming runs

- With a checkpointer, every finished step is saved, so a run cut off by a
  deploy can continue from its last saved step instead of starting over:
  invoke its thread again with an empty input (see
  [Durable Execution](durable_execution.md#what-survives-a-crash)).
- Runs waiting for human approval stay paused in the checkpointer across
  deploys, and resume afterwards (see [Human-in-the-Loop](human_in_the_loop.md)).
- Keep node and tool names stable while threads are paused: a resumed run
  continues at the node it saved.
- Give tools with side effects, such as refunds, an idempotency key, because a
  resumed step can run again.
- Stop the node gracefully: the exporter queue uploads the traces still
  queued as the application stops, for up to its `shutdown:` time (see
  [Tracing](tracing.md#export-to-weavescope)).

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): call options such as `context:`, `trace:` and `run_timeout:`
- [`BeamWeaver.Checkpoint.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.Ecto.html): durable checkpoints
- [`BeamWeaver.Memory.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Memory.Ecto.html): durable memory store
- [`BeamWeaver.Migrations`](https://hexdocs.pm/beam_weaver/BeamWeaver.Migrations.html): creating and checking tables
- [`BeamWeaver.RateLimiter.TokenBucket`](https://hexdocs.pm/beam_weaver/BeamWeaver.RateLimiter.TokenBucket.html): rate limiter buckets in your supervision tree
- [`BeamWeaver.Tracing`](https://hexdocs.pm/beam_weaver/BeamWeaver.Tracing.html): traces and `flush_exporter/1`
