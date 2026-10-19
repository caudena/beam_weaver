# Production Integration

A working agent becomes a production feature when your application owns its
identity, resource lifecycle, failure policy and external actions. BeamWeaver
runs inside your OTP application; it does not supply a job scheduler,
authorization service or automatic restart queue.

Use the [support-agent tutorial](tutorial.md) as the starting point, then
complete the integration decisions below before exposing it to users.

## Define the request boundary

Authenticate the caller before starting a run. Resolve the tenant, user and
conversation in application code, and pass current trusted data through
`context:`. Validate required context fields in the agent. Tool queries must
actually constrain records by that identity; injection alone is not authorization.

Handle all three outcomes: completed state, a waiting interrupt and an error.
A completed agent may have explained a failed action, so inspect structured
outcomes or tool results where the product needs a business success/failure.
[Agents](agents.md#run-an-agent) and [Runtime Context](runtime_context.md) define
those contracts.

## Supervision

Own reusable resources under the appropriate application supervisor:

| Resource | Owner/lifetime |
| --- | --- |
| Ecto repository | Application; start before storage users |
| ETS saver/store/cache | A process that outlives all calls using its tables |
| Provider admission limiter | Shared process for the intended quota scope |
| Agent task | Request owner or durable job owner, depending on expected lifetime |
| Shell/interpreter session | Run/thread owner with idle expiry and explicit cleanup |
| Docker workspace | A long-lived owner for the chosen run/thread/customer scope |
| Trace exporter | Application queue with bounded shutdown drain |

Do not allocate ETS or start containers in agent declarations: declarations
are evaluated on each call. An Ecto adapter is a lightweight value around a
supervised repo; it does not start the repo. [Storage](storage.md) provides
the complete PostgreSQL and SQLite setup.

This complete local application keeps ETS resources in a supervised owner and runs agent work under a task supervisor. ETS is used here so the example runs without a database; replace its saver with the Ecto setup in Storage for restart durability:

```elixir
defmodule MyApp.AgentResources do
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get, do: GenServer.call(__MODULE__, :get)
  @impl true
  def init(_opts), do: {:ok, %{saver: BeamWeaver.Checkpoint.ETS.new(), store: BeamWeaver.Memory.ETS.new()}}
  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}
end

defmodule MyApp.ProductionAgent do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Answer briefly from the supplied conversation."
  run_timeout 90_000
  middleware [{BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 1, initial_delay: 500}]

  context_schema do
    field :customer_id, :string, required: true
  end
end

children = [MyApp.AgentResources, {Task.Supervisor, name: MyApp.AgentTasks}]
{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

try do
  resources = MyApp.AgentResources.get()

  opts = [
    checkpointer: resources.saver,
    store: resources.store,
    config: %{"configurable" => %{"thread_id" => "ada-support-1"}},
    context: %{customer_id: "ada"}
  ]

  task =
    Task.Supervisor.async_nolink(MyApp.AgentTasks, fn ->
      MyApp.ProductionAgent.invoke(%{messages: ["Remember A-1001 arrives Thursday."]}, opts)
    end)

  {:ok, _state} = Task.await(task, 100_000)
  {:ok, saved} = MyApp.ProductionAgent.get_state(opts)
  2 = length(saved.values.messages)
  {:ok, result} = MyApp.ProductionAgent.invoke(%{messages: ["Which day does A-1001 arrive?"]}, opts)
  true = BeamWeaver.Core.Message.text(List.last(result.messages)) =~ "Thursday"
after
  Supervisor.stop(supervisor)
end
```

## Choose durable state deliberately

Use a database checkpointer for conversations, review pauses or workflows that
must survive restarts. ETS only lasts as long as its owner. Reuse a thread ID
for one conversation, authorize all access to it and coordinate simultaneous
writes where the product requires one ordered history.

Use memory namespaces for facts shared across conversations. Use persistent
workspace storage for files that must survive a run. These are different
lifetimes: a persistent checkpoint does not make a temporary local directory
durable, and a persistent file does not automatically restore a conversation.

## Configure credentials and models

Load secrets in your application's runtime configuration. Never rely on a
dependency's config files being evaluated. Validate the selected model through
a real request in the deployment environment: construction alone checks
neither access nor account limits.

Make fallback policy explicit. A fallback can change cost, capability and the
provider receiving data. Keep provider credentials outside agent workspaces
and command environments. [Configuration](configuration.md) and the
[provider reference](providers.md) cover supported settings.

## Bound work

Use a model output limit, provider request timeout, tool/node timeout,
whole-run timeout and graph step budget for their respective boundaries.
Add model/tool call limits where repeated work must be capped. Size rate
limiters for your provider/account/model quota and deployment node count.

Retries multiply across layers. Count provider attempts across model middleware,
graph node retry and job retry rather than treating each as an independent
small budget. Retry mutating actions only with idempotency and reconciliation.
[Durable Execution](durable_execution.md) explains interruption and recovery.

## Protect external actions

Keep tools narrow and validate their arguments and ownership in code. A prompt
or skill is guidance, not an access-control boundary. Use `interrupt_on` when
approval is required, and tie review submissions to current saved state so an
old browser card cannot approve different pending work.

Give external operations stable application IDs. If a timeout leaves the
outcome unknown, query the service before sending another payment, message
or write. A checkpoint cannot roll back an action that already happened.

## Run work outside the request callback

Consume live streams in a task, not in a LiveView callback. Correlate UI events
with a run ID and distinguish provisional tokens, final messages, errors and
review pauses. Cancel request-owned work when its UI owner goes away; keep
longer work under a durable job owner instead.

For restart recovery, persist the thread ID and inspect pending execution
before continuing. Nothing is automatically rescheduled just because the
checkpoint exists. [Streaming](streaming.md#push-tokens-to-a-liveview) covers
consumer ownership; [Subagents](subagents.md#async-subagents) covers remote work.

## Observe behavior and delivery

Record provider identity, model usage, tool outcomes and nested task results.
Use trace IDs for diagnosis without placing secrets or entire customer objects
in metadata. Monitor rate limiting, provider failures, latency and interrupted
runs, along with trace-export backlog and dead letters.

Exporter configuration is not proof of delivery. [Tracing](tracing.md) includes
a real local HTTP delivery example and explains hosted-account requirements.

## Plan retention and migrations

Run library migrations through your deployment process, then verify the
selected adapters' schemas. Back up durable data and encryption keys together
with a recovery procedure. Use stable serialization tags for application
structs that checkpoints must restore after code changes.

Define retention for checkpoints, memories, cached answers, vector records,
files and provider-uploaded resources. Cleanup must include all pages and
namespaces owned by a tenant. A bounded search result is not an exhaustive
account-deletion list. See [Storage](storage.md#keep-tables-small).

## Validate before rollout

Application tests should exercise tool arguments/results, structured answers,
review/resume, duplicate-action prevention and recoverable failures. Use fake
models for deterministic failure branches, then run representative live
integrations with the actual deployed providers and models.

Exercise persistence with the database adapter you deploy. Verify command
workloads in the actual sandbox runtime and inspect generated artifacts.
A passing model call does not prove tool execution, retrieval relevance,
cache hits or restart recovery; check the observable result of each capability.

## Release and shutdown

Stop admitting new work before shutdown where your application supports it.
Let short tasks finish within bounded supervisor budgets; record unfinished
threads for later continuation. Flush telemetry/export queues and collect
workspace artifacts before cleanup. Reconcile external side effects when
completion is ambiguous.

A local package build verifies the package contents and consumer behavior.
Availability through Hex is a separate release step. The installation guide
states the current release target and verification boundary.

## Next steps

Use [Testing](testing.md) for application test patterns,
[Storage](storage.md) for migrations and persistence,
[Tracing](tracing.md) for diagnosis, and
[Durable Execution](durable_execution.md) for retries and recovery.
