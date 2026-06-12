# Durable Execution

Durable execution means a graph or agent saves enough progress to pause,
resume, inspect, fork, or recover without starting the whole workflow again.
BeamWeaver provides this through checkpoint adapters and stable `thread_id`
values.

Use durable execution for:

- human-in-the-loop workflows that pause for approval
- long-running graph work that may fail partway through
- fan-out steps where successful sibling work should not rerun
- conversation state across turns
- time travel, state repair, and checkpoint forks

{% hint style="info" %}
**BeamWeaver Shape**

LangGraph's durable execution guide covers Python `@task` replay, `durability=`
modes, `RunControl`, and `graph.invoke(None, config)`. BeamWeaver's durable
surface is different: compile with a checkpointer, invoke with a stable
`thread_id`, use graph nodes or tools as durable boundaries, resume interrupts
with `BeamWeaver.Graph.Compiled.resume/3` or `BeamWeaver.Agent.resume/3`, and
recover failed graph work by continuing the same checkpointed thread.
{% endhint %}

## Requirements

Durable execution needs three things:

1. Compile the graph or agent with a checkpointer.
2. Invoke it with a stable `thread_id` in `config`.
3. Keep side effects and non-deterministic work at explicit graph or tool
   boundaries, and make them idempotent.

Use `BeamWeaver.Checkpoint.ETS` for local development and tests. Use
`BeamWeaver.Checkpoint.Ecto` for durable Postgres-backed deployments. ETS
checkpoints are process-local and do not survive a VM restart.

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

checkpointer = CheckpointETS.new()

graph =
  Graph.new(name: "DurableExample")
  |> Graph.add_node(:load, fn state ->
    %{loaded_url: state.url}
  end)
  |> Graph.add_node(:summarize, fn state ->
    %{summary: "Fetched #{state.loaded_url}"}
  end)
  |> Graph.add_edge(:load, :summarize)
  |> Graph.add_edge(Graph.start(), :load)
  |> Graph.add_edge(:summarize, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

config = %{"configurable" => %{"thread_id" => "durable-run-1"}}

{:ok, state} =
  Compiled.invoke(graph, %{url: "https://example.com"}, config: config)
```

For production persistence:

```elixir
checkpointer = BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)
graph = Graph.compile!(workflow, checkpointer: checkpointer)
```

Create the tables with your application migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateBeamWeaverCheckpoints do
  use Ecto.Migration

  def up do
    BeamWeaver.Migrations.up(adapters: [:checkpoint])
  end

  def down do
    BeamWeaver.Migrations.down(adapters: [:checkpoint], version: 1)
  end
end
```

## Determinism And Replay

Durable execution does not resume from the exact Elixir line that was running
when a workflow stopped. It resumes from graph execution metadata: checkpointed
state, pending writes, next tasks, interrupt records, and node boundaries.

Design for replay:

- Keep nodes deterministic when possible.
- Split expensive or side-effecting work into separate nodes when each step
  needs its own checkpoint boundary.
- Use `retry:` and `timeout:` on external-service nodes.
- Use idempotency keys for writes to external systems.
- Persist external IDs in graph state as soon as they are created.
- Let unexpected errors surface instead of hiding unknown failure modes.

{% hint style="warning" %}
**Task Deviation**

LangGraph's Python `@task` decorator records task results so a replay can skip
the same side effect inside one entrypoint or node. BeamWeaver does not expose
that decorator. BEAM `Task` is used by the runtime to execute graph work, but an
ordinary `Task.async/1` inside your node is not a separate durable replay
boundary. If a sub-operation must be independently resumable, model it as a
graph node, tool call, or application-level idempotent operation.
{% endhint %}

## Durable Boundaries

The most important durable boundary in BeamWeaver is the graph node. Smaller
nodes give you more places to checkpoint, inspect, retry, and resume.

Less durable shape:

```elixir
Graph.add_node(workflow, :process_order, fn state ->
  invoice = MyApp.Billing.create_invoice!(state.order)
  receipt = MyApp.Email.send_receipt!(state.customer_email, invoice)

  %{invoice_id: invoice.id, receipt_id: receipt.id}
end)
```

If the email send fails after the invoice is created, the whole node may run
again when the graph continues. The external services must make that safe.

More durable shape:

```elixir
workflow =
  Graph.new(name: "OrderProcessing")
  |> Graph.add_node(:create_invoice, fn state ->
    invoice =
      MyApp.Billing.create_invoice!(
        state.order,
        idempotency_key: "invoice:#{state.order_id}"
      )

    %{invoice_id: invoice.id}
  end,
    retry: BeamWeaver.RetryPolicy.new!(max_attempts: 3, retry_on: :transient),
    timeout: 30_000
  )
  |> Graph.add_node(:send_receipt, fn state ->
    receipt =
      MyApp.Email.send_receipt!(
        state.customer_email,
        state.invoice_id,
        idempotency_key: "receipt:#{state.order_id}"
      )

    %{receipt_id: receipt.id}
  end,
    retry: BeamWeaver.RetryPolicy.new!(max_attempts: 3, retry_on: :transient),
    timeout: 30_000
  )
  |> Graph.add_edge(:create_invoice, :send_receipt)
  |> Graph.add_edge(Graph.start(), :create_invoice)
  |> Graph.add_edge(:send_receipt, Graph.end_node())
```

Now invoice creation and receipt delivery are separate graph steps with their
own checkpoint and retry boundaries.

## Fan-Out And Pending Writes

When a super-step fans out to multiple nodes and one node fails, BeamWeaver can
persist successful sibling writes as pending writes. When the same thread
continues, successful sibling work does not need to rerun.

```elixir
alias BeamWeaver.Core.Error
alias BeamWeaver.Graph.Send

graph =
  Graph.new(name: "RecoverableFanout")
  |> Graph.add_node(:fanout, fn _state ->
    [
      %Send{node: :record_invoice, update: %{invoice_id: "inv_123"}},
      %Send{node: :notify_customer, update: %{attempt: 1}}
    ]
  end)
  |> Graph.add_node(:record_invoice, fn state ->
    %{recorded_invoice_id: state.invoice_id}
  end)
  |> Graph.add_node(:notify_customer, fn state ->
    if state[:notification_ready?] do
      %{notification: "sent on attempt #{state.attempt}"}
    else
      {:error, Error.new(:notification_unavailable, "notification service unavailable")}
    end
  end)
  |> Graph.add_edge(Graph.start(), :fanout)
  |> Graph.add_edge(:record_invoice, Graph.end_node())
  |> Graph.add_edge(:notify_customer, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

config = %{"configurable" => %{"thread_id" => "fanout-1"}}

{:error, _error} =
  Compiled.invoke(graph, %{}, config: config)

{:ok, snapshot} =
  Compiled.get_state(graph, config)

snapshot.values.recorded_invoice_id
snapshot.pending_writes

{:ok, state} =
  Compiled.invoke(graph, %{notification_ready?: true}, config: config)
```

`record_invoice` does not rerun in the continuation because its successful
write was checkpointed as a pending write. The failed `notify_customer` branch
continues with the merged state and the new input update.

{% hint style="warning" %}
**External Side Effects**

Pending writes protect BeamWeaver graph state. They do not make an external API,
database, payment, email, or filesystem write transactional. Use external
idempotency keys, uniqueness constraints, dedupe records, or compensation logic
for real side effects.
{% endhint %}

## Human-In-The-Loop Resume

Interrupts are durable because the interrupt and state are saved in the
checkpointer. Resume with the same `thread_id`.

```elixir
review = fn state ->
  decision =
    BeamWeaver.Graph.interrupt(%{
      action: "approve_send",
      draft: state.draft
    })

  %{review_decision: decision}
end

graph =
  Graph.new(name: "ReviewFlow")
  |> Graph.add_node(:review, review)
  |> Graph.add_edge(Graph.start(), :review)
  |> Graph.add_edge(:review, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

config = %{"configurable" => %{"thread_id" => "review-1"}}

{:interrupted, interrupt} =
  Compiled.invoke(graph, %{draft: "Send this response?"}, config: config)

{:ok, state} =
  Compiled.resume(graph, %{interrupt.id => "approved"}, config: config)
```

Agents expose the same concept through `BeamWeaver.Agent.resume/3` and
`BeamWeaver.Agent.resume_review/3` when human-in-the-loop middleware is used.

## Recover After Failure

To recover failed graph work, keep the same checkpointer and `thread_id`.
BeamWeaver decides where to continue from the checkpoint metadata.

Common recovery patterns:

| Situation | BeamWeaver Call |
| --- | --- |
| Human interrupt | `BeamWeaver.Graph.Compiled.resume(graph, resume_value, config: config)` |
| Agent HITL review | Your module-defined agent's `resume/2`, `resume/3`, or `resume_review/3` with the same `config` |
| Failed fan-out with pending writes | `BeamWeaver.Graph.Compiled.invoke(graph, input_update, config: config)` |
| Failed error handler or stored resume continuation with no new value | `BeamWeaver.Graph.Compiled.resume(graph, nil, config: config)` |
| Fork from an older checkpoint | `BeamWeaver.Graph.Compiled.update_state(graph, snapshot.config, values, as_node: node)` then invoke or inspect from the returned config |

{% hint style="info" %}
**No `invoke(nil)`**

LangGraph Python examples can resume some failures with `graph.invoke(None,
config)`. BeamWeaver `BeamWeaver.Graph.Compiled.invoke/3` requires a map input or a
`%BeamWeaver.Graph.Command{}`. Use `%{}` when you are invoking a checkpointed
thread without new state, or use `BeamWeaver.Graph.Compiled.resume/3` when the
runtime expects a resume value.
{% endhint %}

## Starting Points

BeamWeaver continuation starts from graph execution boundaries:

| Graph Shape | Continuation Boundary |
| --- | --- |
| Sequential graph | The next checkpointed node or pending task recorded in the thread. |
| Failed super-step | Successful pending writes are applied; failed or pending tasks continue. |
| Interrupted node | The node resumes through `BeamWeaver.Graph.interrupt/1` with the provided value. |
| Subgraph | The parent graph carries checkpoint namespace metadata so the nested graph can resume its own checkpointed task. |
| Agent | The compiled agent graph resumes through the same graph runtime. |

BeamWeaver does not expose LangGraph's Python Functional API entrypoint
semantics, so there is no `@entrypoint` replay boundary to document.

## Durability Modes

LangGraph documents per-call durability modes: `"exit"`, `"async"`, and
`"sync"`. BeamWeaver does not currently expose a `durability:` option on
`invoke/3` or `stream_events/3`.

Control durability through the pieces BeamWeaver does expose:

| Concern | BeamWeaver Control |
| --- | --- |
| Process-local vs restart-durable state | Choose `Checkpoint.ETS` or `Checkpoint.Ecto`. |
| Checkpoint retention | Use `Checkpoint.Ecto.new(shallow?: true)` or pruning functions when history is not required. |
| Resume boundaries | Split work into graph nodes or tools. |
| Failure behavior within a super-step | Use `failure_policy: :panic` or `:proceed`. |
| Transient failures | Use node `retry:` policies. |
| Long-running work | Use node `timeout:`, graph `step_timeout:`, `run_timeout:`, and `recursion_limit:`. |

Example:

```elixir
graph =
  workflow
  |> Graph.add_node(:call_provider, call_provider,
    retry: BeamWeaver.RetryPolicy.new!(max_attempts: 3, retry_on: :transient),
    timeout: 30_000
  )
  |> Graph.compile!(
    checkpointer: checkpointer,
    failure_policy: :proceed,
    step_timeout: 60_000,
    run_timeout: 300_000
  )

Compiled.invoke(graph, input,
  config: config,
  recursion_limit: 50
)
```

`failure_policy: :proceed` lets a parallel super-step collect successful writes
and sibling failures before halting. Hard budgets such as `step_timeout` and
`run_timeout` still stop the run.

## Graceful Shutdown

LangGraph documents `RunControl`, `GraphDrained`, `request_drain()`, and
`runtime.drain_requested` for cooperative drain. BeamWeaver does not currently
expose an equivalent graph drain API.

Operational guidance:

- Prefer supervised graph/agent processes and durable Ecto checkpoints for
  production work.
- Let in-flight calls finish when possible before terminating a service.
- Use node and graph timeouts to bound work.
- After restart, continue the same `thread_id` from the latest checkpoint.
- Treat hard process termination as potentially losing the current in-flight
  super-step if it has not checkpointed yet.

If a product needs cooperative drain semantics, add an application-level
shutdown flag that nodes check before starting expensive optional work. That is
not the same as LangGraph's `RunControl`; it is ordinary application logic.

## Unsupported Or Different From Official LangGraph Docs

| Official LangGraph Feature | BeamWeaver Status |
| --- | --- |
| Python `@task` decorator for durable replay inside a node or Functional API entrypoint. | Not supported. Use graph nodes, tools, and application idempotency boundaries. |
| Python Functional API `@entrypoint`. | Not supported. Use `BeamWeaver.Graph` or ordinary Elixir functions. |
| Per-call `durability` modes (`"exit"`, `"async"`, `"sync"`). | Not currently exposed. Choose adapters and node granularity instead. |
| `graph.invoke(None, config)` failure resume. | `BeamWeaver.Graph.Compiled.invoke/3` requires map input or a command. Use `%{}` or `BeamWeaver.Graph.Compiled.resume/3` depending on the continuation. |
| `RunControl`, `GraphDrained`, `request_drain()`, `runtime.drain_requested`. | Not implemented as a BeamWeaver graph API. |
| Hosted agent-server persistence. | Not built in. Configure checkpoint adapters explicitly. |
| Automatic Hosted LangGraph deployment behavior. | Not a BeamWeaver feature. Run BeamWeaver under your Elixir/OTP application supervision. |

## Related Guides

- [Persistence](persistence.md)
- [Fault Tolerance](fault_tolerance.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Workflows And Agents](workflows_and_agents.md)
- [Thinking In BeamWeaver](thinking_in_beamweaver.md)
- [Graph](graph.md)
- [Short-Term Memory](short_term_memory.md)
- [Runtime](runtime.md)
- [Event Streaming](event_streaming.md)
