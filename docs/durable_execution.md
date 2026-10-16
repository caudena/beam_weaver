# Durable Execution

A graph or agent with a checkpointer saves its progress after every step, so
when a node fails, a server restarts or a deploy stops a run halfway, you
continue the run from its last step instead of starting over. This page
shows how to continue runs, how to write nodes that are safe to run again, and
how retries, timeouts and error handlers deal with failures.

```elixir
defmodule MyApp.RefundFlow do
  use BeamWeaver.Agent

  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_reducer(:log, &(&1 ++ &2))
    |> Graph.add_node(:issue_refund, &issue_refund/1)
    |> Graph.add_node(:notify_customer, &notify_customer/2)
    |> Graph.add_edge(Graph.start(), :issue_refund)
    |> Graph.add_edge(:issue_refund, :notify_customer)
    |> Graph.add_edge(:notify_customer, Graph.end_node())
  end

  # A real node would call the payment API here.
  def issue_refund(%{order_id: order_id}) do
    %{refund_id: "R-#{order_id}", log: ["refund issued"]}
  end

  # In this example, `context: %{mail: :down}` stands in for a mail outage.
  def notify_customer(%{refund_id: refund_id}, runtime) do
    if runtime.context[:mail] == :down, do: raise("mail service unavailable")
    %{log: ["customer notified about #{refund_id}"]}
  end
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

MyApp.RefundFlow.invoke(%{order_id: "A-1001"}, [context: %{mail: :down}] ++ opts)
#=> {:error, %BeamWeaver.Core.Error{type: :node_exception, message: "mail service unavailable"}}
```

The refund went through, then the mail service failed. The checkpoint after
`issue_refund` was saved before `notify_customer` started, so the thread
knows where it stopped:

```elixir
{:ok, snapshot} = MyApp.RefundFlow.get_state(opts)
{snapshot.values.refund_id, snapshot.next}
#=> {"R-A-1001", ["notify_customer"]}
```

When the mail service is back, continue the thread: invoke it again with an
empty input, which means "no new input". Only the nodes in `next` run:

```elixir
{:ok, state} = MyApp.RefundFlow.invoke(%{}, opts)
state.log
#=> ["refund issued", "customer notified about R-A-1001"]
```

Each node that finishes adds a line to `log` (its reducer appends), so the
log shows that the refund was issued once.

## What survives a crash

When a crash or a deploy stops a run, its thread keeps:

- the state after the last finished step, and the nodes that come next;
- the updates of nodes that finished in a step where another node failed
  (see [Fan-out and pending writes](#fan-out-and-pending-writes));
- pauses that wait for a person, and errors that wait for an
  [error handler](#error-handlers).

The step that was running when the process stopped is lost; its nodes run
again from their start. For this to hold across restarts, you need:

- **A durable saver.** `BeamWeaver.Checkpoint.Ecto` keeps checkpoints in
  Postgres or SQLite. `Checkpoint.ETS` lives in memory and goes away with the
  process that created it.
- **Thread ids you can find again**, such as ticket ids, kept in your own
  tables or job queue.

Nothing continues by itself after a restart: BeamWeaver doesn't schedule
runs. Continue unfinished threads yourself, from a job queue, when your
application starts, or when the customer comes back. A run stopped halfway
when the latest snapshot of its thread lists nodes in `next` and has no
interrupts:

```elixir
defmodule MyApp.Refunds do
  # Continues a refund run that a failure, a crash or a deploy stopped.
  def continue(ticket_id) do
    saver = BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)
    opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => ticket_id}}]

    case MyApp.RefundFlow.get_state(opts) do
      {:ok, %{next: [_ | _], interrupts: []}} ->
        MyApp.RefundFlow.invoke(%{}, opts)

      {:ok, snapshot} ->
        {:ok, snapshot.values}

      :error ->
        {:error, :unknown_ticket}
    end
  end
end
```

With no new input, the run takes the thread's latest checkpoint and runs the
nodes in its `next`, the ones the stopped run hadn't finished;
`resume(nil, opts)` does the same. Check `next` first, as above: on a thread
that finished, an empty input starts a new run from the first node. A thread
with interrupts waits for a person instead; resume it as
[Human-in-the-Loop](human_in_the_loop.md) shows. To continue from one exact
checkpoint, pass its `config` (see
[Replay from an earlier checkpoint](checkpoints.md#replay-from-an-earlier-checkpoint)).

## Determinism and side effects

Continuing a run doesn't replay your code line by line. Nodes that finished
are skipped and their results come from the checkpoint; nodes that didn't
finish run again from their start. Write nodes with that in mind:

- **One side effect per node.** If `issue_refund` also sent the email, the
  mail failure above would have run it again and refunded twice.
- **Make side effects idempotent.** A node can still run twice: when it fails
  after its outside call succeeded, or when a crash hits it. Send an
  idempotency key built from the state, such as `"refund-#{order_id}"`, so the
  payment API ignores the repeat.
- **Save what you can't compute again.** Put generated ids, timestamps and
  model answers in the state as soon as you have them. Later nodes read them
  from the checkpoint instead of producing new ones.
- **Expect interrupts to rerun their node.** A node that calls
  `BeamWeaver.Graph.interrupt/1` starts over when it resumes, so do side
  effects after the interrupt (see
  [Human-in-the-Loop](human_in_the_loop.md#pause-a-graph-node)).

The same rules make [time travel](checkpoints.md#replay-from-an-earlier-checkpoint)
safe, since a replay reruns nodes on purpose.

## Fan-out and pending writes

When nodes run in parallel and one of them fails, the others still finish.
BeamWeaver saves their updates with the error, as pending writes, before the
run returns `{:error, error}`. Continuing the thread runs only the node that
failed; then the run goes on from every node of that step, the ones that had
finished included:

```elixir
defmodule MyApp.OrderDigest do
  use BeamWeaver.Agent

  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_reducer(:log, &(&1 ++ &2))
    |> Graph.add_node(:lookup_order, &lookup_order/1)
    |> Graph.add_node(:check_carrier, &check_carrier/2)
    |> Graph.add_node(:reply, &reply/1)
    |> Graph.add_edge(Graph.start(), :lookup_order)
    |> Graph.add_edge(Graph.start(), :check_carrier)
    |> Graph.add_join([:lookup_order, :check_carrier], :reply)
    |> Graph.add_edge(:reply, Graph.end_node())
  end

  def lookup_order(%{order_id: order_id}) do
    %{status: "#{order_id} shipped on Monday", log: ["order looked up"]}
  end

  def check_carrier(_state, runtime) do
    if runtime.context[:carrier] == :down, do: raise("carrier API is down")
    %{eta: "Thursday", log: ["carrier checked"]}
  end

  def reply(state), do: %{reply: "#{state.status}, arriving #{state.eta}."}
end

digest = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-43"}}]
{:error, _error} = MyApp.OrderDigest.invoke(%{order_id: "A-1001"}, [context: %{carrier: :down}] ++ digest)

{:ok, snapshot} = MyApp.OrderDigest.get_state(digest)
{snapshot.values.log, snapshot.next}
#=> {["order looked up"], ["check_carrier"]}
```

```elixir
{:ok, state} = MyApp.OrderDigest.invoke(%{}, digest)
{state.reply, state.log}
#=> {"A-1001 shipped on Monday, arriving Thursday.", ["order looked up", "carrier checked"]}
```

The join still counts `lookup_order`, whose result came from the pending
writes, so `reply` runs once both branches are done. Each
[`Send`](graphs.md#map-reduce-with-send) counts on its own the same way:
after a map-reduce step fails partway, continuing runs only the `Send`s that
didn't finish, and `snapshot.next` names their node once for each. Pending
writes protect the graph's state, not the outside world: a failed node's
outside call may have happened anyway, so keep it idempotent.

## When checkpoints are written

BeamWeaver writes a checkpoint when a run starts and at the end of every
step, and the next step starts only after the write returns. There is no
setting to defer or batch these writes, so every finished step is as safe as
your saver. Each write is a round trip to the saver's storage (the run reads
the thread's checkpoint only when it starts, not before each write); if that
is too slow, use fewer, larger nodes. To keep fewer checkpoints, see
[Manage checkpoints](checkpoints.md#manage-checkpoints).

## Graceful shutdown

BeamWeaver has no drain mode. A run is ordinary code in the process that
called `invoke/2`, and each node runs in a task linked to that process, so
the run stops when that process stops. Plan for it:

- Keep steps short and give them [timeouts](#timeouts), so a lost step is
  cheap to redo.
- Start runs from a job queue, such as Oban, or a supervised process that
  records the thread id, so you know which threads were in flight.
- After the restart, continue those threads as in
  [What survives a crash](#what-survives-a-crash).

## Retries

`retry:` on `BeamWeaver.Graph.add_node/4` runs a failed node again within the
same run. It takes a keyword list of `BeamWeaver.RetryPolicy` options, a
`%BeamWeaver.RetryPolicy{}`, or a number of retries. Here the carrier API
fails twice before it answers:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

check_carrier = fn _state, runtime ->
  attempt = runtime.execution.node_attempt
  if attempt < 3, do: raise("carrier API timed out")
  %{eta: "Thursday", attempts: attempt}
end

carrier =
  Graph.new()
  |> Graph.add_node(:check_carrier, check_carrier, retry: [max_attempts: 3, initial_delay: 10])
  |> Graph.add_edge(Graph.start(), :check_carrier)
  |> Graph.add_edge(:check_carrier, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(carrier, %{order_id: "A-1001"})
#=> {:ok, %{order_id: "A-1001", eta: "Thursday", attempts: 3}}
```

`runtime.execution.node_attempt` is the attempt number, starting at 1; use it
to log or to switch to a fallback. Without `retry:`, a node runs once.

| Option | Default | Meaning |
|---|---|---|
| `max_attempts` | `3` | Attempts in total, the first one included. |
| `initial_delay` | `0` | Milliseconds to wait before the first retry. |
| `backoff` | `2.0` | Each wait is this many times the one before. |
| `max_delay` | `5_000` | The longest wait, in milliseconds. |
| `jitter` | `false` | `true` adds a random wait up to the current one; an integer adds up to that many milliseconds. |
| `retry_on` | `:error` | Which errors to retry. |

`retry_on:` takes:

- `:error`, any `%BeamWeaver.Core.Error{}`: an error the node returns, an
  exception it raises (`:node_exception`) or a timeout (`:node_timeout`);
- `:transient`, only errors that look temporary, such as rate limits,
  overloaded or unavailable servers (statuses 429, 500, 502, 503, 504 and
  529), closed connections and timeouts
  (`BeamWeaver.RetryPredicates.transient?/1`);
- an error type or a list of them, such as `[:rate_limit, :node_timeout]`;
- a function that takes the error and returns `true` to retry.

Agents retry model calls with middleware instead; see `ModelRetry` in
[Built-in Middleware](builtin_middleware.md).

## Timeouts

A node runs as long as it needs unless you give it a time limit with
`timeout:`, in milliseconds. A node that runs over it is stopped and fails
with `:node_timeout`, which `retry:` can retry:

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

Give a node that calls a model, an agent or a slow API a limit that fits it,
such as `timeout: 120_000`, so a call that hangs fails instead of waiting
forever. An agent's model steps use the `timeout:` of its model, and its tool calls
the `tool_timeout` declaration (see [Agents](agents.md#declarations)). Three
more limits bound a whole run. Pass them on a call; `step_timeout:` and
`run_timeout:` also work as `Graph.compile!/2` options and as declarations in
an agent or graph module, such as `run_timeout 300_000`:

| Option | Limits | Error type |
|---|---|---|
| `timeout:` on a node | one attempt of that node | `:node_timeout` |
| `step_timeout:` | one step, all its parallel nodes together | `:step_timeout` |
| `run_timeout:` | the whole call | `:run_timeout` |
| `recursion_limit:` | the number of steps | `:recursion_limit` |

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

A limit is a hard stop; there is no heartbeat that extends it while a node
makes progress. `timeout:` also takes a `BeamWeaver.TimeoutPolicy`, and then
uses the smaller of its `run_timeout` and `idle_timeout`.

## Error handlers

`error_handler:` runs when a node still fails after its retries. It takes
the error, the state and the runtime, and returns what a node returns: an
update, or a `BeamWeaver.Graph.Command` that also chooses the next node.
Here a refund to an expired card becomes store credit:

```elixir
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

`goto:` replaces the node's edges, so `confirm` doesn't run. A handler can
also take only the error: `fn error -> %{problem: error.message} end`.

If the handler itself raises, the run fails with `:node_error_handler_failed`
and `details.handled_error` holds the node's error. With a checkpointer, the
node's error is saved first, so continuing the thread runs the handler again,
not the node. Interrupts are not errors: `Graph.interrupt/1` skips both
retries and handlers.

## Defaults for many nodes

`BeamWeaver.Graph.set_node_defaults/2` sets options for the nodes you add
after it. A node's own options win, and the defaults don't reach the nodes of
a subgraph:

```elixir
Graph.new()
|> Graph.set_node_defaults(retry: [max_attempts: 3, retry_on: :transient], timeout: 30_000)
|> Graph.add_node(:lookup_order, &MyApp.OrderDigest.lookup_order/1)
|> Graph.add_node(:check_carrier, &MyApp.OrderDigest.check_carrier/2, timeout: 10_000)
```

## Parallel and subgraph failures

In a step where several nodes run, one failure doesn't stop the others (see
[Fan-out and pending writes](#fan-out-and-pending-writes)), but
`step_timeout:` and `run_timeout:` stop every node of the step at once.

A graph that runs as a node of another graph hands its error to that node,
so the parent node's `retry:` and `error_handler:` apply to it:

```elixir
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

With a checkpointer, a retry of the parent node, or continuing the parent's
thread, continues the subgraph where it failed: its nodes that finished don't
run again, and it gets only what changed in the parent's state since it
started. See [Subgraphs](subgraphs.md) for more on graphs inside graphs.

## Telemetry for failures

Graph runs emit `:telemetry` events for failures. Attach handlers to send
alerts or count errors:

| Event | Sent when | Metadata |
|---|---|---|
| `[:beam_weaver, :graph, :retry]` | a node is about to be retried | `attempt`, `error` |
| `[:beam_weaver, :graph, :node_failure]` | a node failed for good: its retries ran out and no error handler took over | `graph`, `node`, `step`, `error` |
| `[:beam_weaver, :graph, :node_timeout]` | the same, when the last attempt ran over its `timeout:` | `graph`, `node`, `step`, `error` |
| `[:beam_weaver, :graph, :node_exit]` | the same, when the last attempt's process exited before it returned | `graph`, `node`, `step`, `error` |
| `[:beam_weaver, :graph, :step_timeout]` | a step ran over `step_timeout:` | `node`, `step`, `error` |
| `[:beam_weaver, :graph, :run_timeout]` | a run ran over `run_timeout:` | `node`, `step`, `error` |
| `[:beam_weaver, :graph, :node_cancel]` | a step or run limit stopped a running node | `node`, `step` |
| `[:beam_weaver, :graph, :exception]` | a run failed | `graph`, `run_id`, `error` |

```elixir
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

In an application, attach handlers once in `Application.start/2` and let them
log or report the error. Handlers run inside the graph run, so keep them
fast. For a full trace of each run, see [Tracing](tracing.md).

## Provider-native replay

Checkpoints store an agent's messages in BeamWeaver's own format. If your
application stores provider turns itself, for example to send a conversation
back to the same provider after a restart, keep exactly the assistant content
that provider needs. `BeamWeaver.Provider.Response.normalize_execution_result/3`
returns the message, what the turn means (its outcome) and `replay`, a small
JSON-safe copy of the turn that is tied to one provider, model and profile:

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Provider.{Replay, Response}

model = BeamWeaver.Models.init_chat_model!("fake:chat")
binding = %{provider: :anthropic, model: "claude-haiku-4-5", profile: "claude-haiku-4-5"}
reply = Message.assistant("Order A-1001 shipped on Monday.")

{:ok, turn} = Response.normalize_execution_result(model, reply, replay_binding: binding)
turn.outcome.turn_disposition
#=> :final_output
```

Store `turn.replay` next to the message. It keeps content blocks, tool calls
and provider-native blocks, and leaves out usage, raw responses and tool
results. `turn.outcome.turn_disposition` says what the turn means, such as
`:final_output`, `:awaiting_client_tools` or `:context_limit`; branch on it
instead of guessing from the text. Before you send the turn back, restore it
against the binding you expect:

```elixir
{:ok, restored} = Replay.restore(turn.replay, binding)
Message.text(restored)
#=> "Order A-1001 shipped on Monday."
```

A copy made for another provider, model or profile returns
`{:error, %BeamWeaver.Core.Error{type: :provider_replay_binding_mismatch}}`
instead of a message.

## Reference

- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): `add_node/4` with `retry:`, `timeout:` and `error_handler:`, and `set_node_defaults/2`
- [`BeamWeaver.Graph.Compiled`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Compiled.html): running compiled graphs and reading their state
- [`BeamWeaver.Graph.Command`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Command.html): update the state and choose the next node from a handler
- [`BeamWeaver.RetryPolicy`](https://hexdocs.pm/beam_weaver/BeamWeaver.RetryPolicy.html): retry options
- [`BeamWeaver.RetryPredicates`](https://hexdocs.pm/beam_weaver/BeamWeaver.RetryPredicates.html): which errors count as transient
- [`BeamWeaver.TimeoutPolicy`](https://hexdocs.pm/beam_weaver/BeamWeaver.TimeoutPolicy.html): timeout policies for nodes
- [`BeamWeaver.Checkpoint.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.Ecto.html): durable checkpoints in Postgres or SQLite
- [`BeamWeaver.Provider.Response`](https://hexdocs.pm/beam_weaver/BeamWeaver.Provider.Response.html): `normalize_execution_result/3`
- [`BeamWeaver.Provider.Replay`](https://hexdocs.pm/beam_weaver/BeamWeaver.Provider.Replay.html): restoring provider-native turns
- [`BeamWeaver.Provider.Outcome`](https://hexdocs.pm/beam_weaver/BeamWeaver.Provider.Outcome.html): what a provider turn means
