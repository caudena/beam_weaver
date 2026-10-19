# Durable Execution

Durability means recovering recorded progress and safely repeating unfinished
work. BeamWeaver checkpoints graph steps; your application supplies durable
storage, identifies unfinished threads and schedules continuation. External
side effects still need idempotency.

## Continue after a failed step

This local example makes no payment or email request. It records a sample
receipt, deliberately fails the notification step, then continues:

```elixir
defmodule MyApp.RecoverableFlow do
  use BeamWeaver.Graph

  graph do
    state do
      channel :log, merge: :list
    end

    node :record, fn %{order_id: id} -> %{receipt: "R-#{id}", log: ["recorded"]} end
    node :notify, &__MODULE__.notify/2
    edge start(), :record
    edge :record, :notify
    edge :notify, finish()
  end

  def notify(%{receipt: receipt}, runtime) do
    if runtime.context.mail_available,
      do: %{log: ["notified #{receipt}"]},
      else: {:error, BeamWeaver.Core.Error.new(:mail_unavailable, "Notification service is unavailable")}
  end
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "recover-1"}}]
{:error, error} = MyApp.RecoverableFlow.invoke(%{order_id: "A-1001"}, [context: %{mail_available: false}] ++ opts)
:mail_unavailable = error.type
{:ok, snapshot} = MyApp.RecoverableFlow.get_state(opts)
["notify"] = snapshot.next
["recorded"] = snapshot.values.log

{:ok, recovered} = MyApp.RecoverableFlow.invoke(%{}, [context: %{mail_available: true}] ++ opts)
["recorded", "notified R-A-1001"] = recovered.log
```

The completed record step did not rerun. ETS demonstrates continuation within
this process; use [database storage](storage.md) to retain the checkpoint
across a process/node restart.

## What survives a crash

Persisted state includes completed steps, pending work, saved successful
sibling updates and interrupts. Unfinished nodes restart from their beginning;
there is no continuation of arbitrary Elixir stack frames.

Keep thread IDs in your job/application records. After restart, inspect the
latest snapshot. Nonempty `next` with no interrupts identifies unfinished work
that can be continued with empty input or `resume(nil, opts)`. A completed
thread invoked with empty input can start a new run, so inspect first.
Waiting human input must be resumed through its decision contract.

New input has different routing semantics: a partially failed/interrupted step
merges it before continuing unfinished tasks; a new input after a breakpoint
or crash without a partially stopped step starts a new run. Use empty input
when the intent is continuation, not another turn. See [Checkpoints](checkpoints.md).

## Determinism and side effects

Split independent external effects into separate nodes. Use a stable
application operation ID for idempotency; do not generate a new one on every
retry. Persist generated IDs and provider results before later steps need them.

A provider can finish an operation before the caller times out or crashes.
Checkpointing cannot determine that external outcome. Reconcile using the
provider's operation/idempotency API before submitting again. The same rule
applies to replay and to code before a graph interrupt, which runs again.

## Fan-out and pending writes

Successful parallel siblings can finish after another fails. Their updates
are saved as pending writes and restored on continuation; only unfinished
nodes or individual sends rerun. Joins retain completed arrivals.
Step/run timeouts cancel the whole running step, unlike an ordinary single
node failure. An external action may still have happened before cancellation.

## Retries

A node `retry:` policy repeats that node within the run. This deterministic
example uses execution metadata to demonstrate three attempts:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

retrying =
  Graph.new()
  |> Graph.add_node(
    :fetch,
    fn _state, runtime ->
      attempt = runtime.execution.node_attempt

      if attempt < 3,
        do: {:error, BeamWeaver.Core.Error.new(:connection, "Temporary failure")},
        else: %{attempts: attempt, value: "ready"}
    end,
    retry: [max_attempts: 3, initial_delay: 10]
  )
  |> Graph.add_edge(Graph.start(), :fetch)
  |> Graph.add_edge(:fetch, Graph.end_node())
  |> Graph.compile!()

{:ok, %{attempts: 3, value: "ready"}} = Compiled.invoke(retrying, %{})
```

Without a retry policy, a node runs once. `max_attempts` includes the initial
attempt; middleware `max_retries` counts additional attempts. Shared options
include initial delay, backoff, maximum delay, jitter and `retry_on:`.
Retry predicates can select transient errors, named types or a function.
Explicit nonretryable errors should fail promptly.

Agent model retries belong in `ModelRetry` middleware. Avoid multiplying node,
model and job retries without calculating the total possible external calls.

## Timeouts

| Budget | Scope | Failure |
| --- | --- | --- |
| Node `timeout:` | One attempt | `:node_timeout` |
| `step_timeout:` | All nodes in a step | `:step_timeout` |
| `run_timeout:` | Whole call | `:run_timeout` |
| `recursion_limit:` | Number of supersteps | `:recursion_limit` |

Time units are milliseconds. Nodes have no timeout by default. Agent model
steps use the model timeout; tools have `tool_timeout`. A `TimeoutPolicy`
uses the smaller configured run/idle bound here; progress does not reset a
heartbeat timer. Set budgets that account for nested work and retries.

This local stand-in never responds. The node timeout terminates the attempt:

```elixir
# The carrier API never answers.
stuck = fn _state -> Process.sleep(:infinity) end

stuck_carrier =
  Graph.new()
  |> Graph.add_node(:check_carrier, stuck, timeout: 10)
  |> Graph.add_edge(Graph.start(), :check_carrier)
  |> Graph.add_edge(:check_carrier, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(stuck_carrier, %{})
#=> {:error, %BeamWeaver.Core.Error{type: :node_timeout, details: %{node: "check_carrier", timeout: 10}}}
```

The whole-run budget also bounds a node without an attempt timeout:

```elixir
waiting =
  Graph.new()
  |> Graph.add_node(:check_carrier, stuck)
  |> Graph.add_edge(Graph.start(), :check_carrier)
  |> Graph.add_edge(:check_carrier, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(waiting, %{}, run_timeout: 10)
#=> {:error, %BeamWeaver.Core.Error{type: :run_timeout}}
```

## Error handlers

After retry exhaustion, a node's `error_handler:` can return an update or
`Graph.Command` recovery route. It accepts error alone or error/state/runtime.
Do not silently convert a failed business operation into a success claim.
Represent an alternative outcome explicitly.

If the handler raises, the run returns `:node_error_handler_failed` with the
original handled error. With checkpoint storage, continuation retries the
pending handler rather than the already-failed node. Interrupts bypass both
ordinary retries and error handlers.

An error handler can select a compensating path. This example records a local credit decision; a real payment action still needs idempotency:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Core.Error
alias BeamWeaver.Graph.Command

refund_to_card = fn _state -> {:error, Error.new(:card_expired, "the card has expired")} end

offer_credit = fn error, _state, _runtime ->
  %Command{update: %{problem: error.message}, goto: :store_credit}
end

store_credit = fn state -> %{reply: "Sorry, #{state.problem}. We added store credit."} end

refund =
  Graph.new()
  |> Graph.add_node(:refund_to_card, refund_to_card, error_handler: offer_credit)
  |> Graph.add_node(:confirm, fn _state -> %{reply: "Your refund is on its way."} end)
  |> Graph.add_node(:store_credit, store_credit)
  |> Graph.add_edge(Graph.start(), :refund_to_card)
  |> Graph.add_edge(:refund_to_card, :confirm)
  |> Graph.add_edge(:confirm, Graph.end_node())
  |> Graph.add_edge(:store_credit, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(refund, %{})
state.reply
#=> "Sorry, the card has expired. We added store credit."
```

## Defaults for many nodes

`Graph.set_node_defaults/2` applies options to nodes added afterward. Explicit
node options override them; nested graphs own their own node defaults.
Use defaults for consistent timeout/retry policy, then specialize mutating or
long-running steps.

Defaults apply to subsequent nodes; a node can override one setting. Both steps below execute:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

flow =
  Graph.new()
  |> Graph.set_node_defaults(retry: [max_attempts: 3, retry_on: :transient], timeout: 30_000)
  |> Graph.add_node(:lookup, fn _ -> %{status: "shipped"} end)
  |> Graph.add_node(:carrier, fn _ -> %{delivery: "Thursday"} end, timeout: 10_000)
  |> Graph.add_edge(Graph.start(), :lookup)
  |> Graph.add_edge(:lookup, :carrier)
  |> Graph.add_edge(:carrier, Graph.end_node())
  |> Graph.compile!()

{:ok, %{status: "shipped", delivery: "Thursday"}} = Compiled.invoke(flow, %{})
```

## When checkpoints are written

The runtime saves an input checkpoint and a checkpoint at each completed step,
waiting for the write before the next step. There is no deferred-write mode.
Storage latency is part of workflow latency. Larger nodes reduce writes but
increase the amount of work that may need repetition after failure.

## Graceful shutdown

BeamWeaver is not a job scheduler and has no global drain mode. Your supervisor
or job queue owns run admission, cancellation and restart scheduling. Record
in-flight thread IDs, stop accepting new work during shutdown, and continue
unfinished threads after restart. Keep critical steps short and idempotent.

## Parallel and subgraph failures

A child failure becomes a failure of its parent node, so the parent's node
retry/error policy applies. With checkpoints, nested continuation can retain
completed child work. Keep child state namespaces distinct and inspect both
parent and child events when diagnosing retries. See [Subgraphs](subgraphs.md).

A parent can handle a child graph failure:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

billing =
  Graph.new()
  |> Graph.add_node(:refund_to_card, refund_to_card)
  |> Graph.add_edge(Graph.start(), :refund_to_card)
  |> Graph.add_edge(:refund_to_card, Graph.end_node())
  |> Graph.compile!()

desk =
  Graph.new()
  |> Graph.add_node(:billing, billing, error_handler: fn error -> %{escalated: error.type} end)
  |> Graph.add_edge(Graph.start(), :billing)
  |> Graph.add_edge(:billing, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(desk, %{})
#=> {:ok, %{escalated: :card_expired}}
```

## Telemetry for failures

Graph telemetry includes retry, node failure/timeout/exit, step/run timeout,
node cancellation and run exception events under `[:beam_weaver, :graph, ...]`.
Metadata identifies graph/node/step and the error where applicable.
Attach handlers once at startup and keep them fast; handlers execute in the
emitting process. [Tracing](tracing.md) covers full-run diagnostics.

Attach an application handler, observe the failed node, then detach it:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

defmodule MyApp.GraphAlerts do
  def handle_event([:beam_weaver, :graph, :node_failure], _measurements, metadata, pid) do
    send(pid, {:node_failed, metadata.node, metadata.error.type})
  end
end

event = [:beam_weaver, :graph, :node_failure]
:telemetry.attach("graph-alerts", event, &MyApp.GraphAlerts.handle_event/4, self())

{:error, _error} = Compiled.invoke(billing, %{})
:telemetry.detach("graph-alerts")

receive do
  {:node_failed, "refund_to_card", type} -> type
after
  1_000 -> :no_event
end

#=> :card_expired
```

## Provider-native replay

When your application stores provider turns directly, preserve the full turn
contract, not just rendered text. `Provider.Response.normalize_execution_result/3`
returns message, outcome and a JSON-safe replay value bound to provider/model/
profile. `Provider.Replay` restores it against the expected binding and
rejects mismatches.

Replay retains provider-native content and tool calls but not your tool
results or all raw response metadata. Store the rest of the conversation too.
Use `turn_disposition` to distinguish final output, pending client tools,
filtering and context limits. This is separate from graph checkpoint replay.
