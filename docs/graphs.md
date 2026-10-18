# Graphs

A graph runs functions you write, called nodes, in an order you define with
edges, and every node reads and updates one shared state map. Use a graph when
you know the steps in advance, such as a pipeline, a router, a review loop or a
workflow that waits for a person; use an [agent](agents.md) when the model
should decide what to do next.

```elixir
defmodule MyApp.TicketTriage do
  use BeamWeaver.Graph

  graph do
    node :classify, &__MODULE__.classify/1
    node :billing, &__MODULE__.billing/1
    node :shipping, &__MODULE__.shipping/1

    edge start(), :classify
    edge :classify, :billing, when: %{category: :billing}
    edge :classify, :shipping, default: true
    edge :billing, finish()
    edge :shipping, finish()
  end

  def classify(%{subject: subject}) do
    %{category: if(subject =~ ~r/refund/i, do: :billing, else: :shipping)}
  end

  def billing(_state), do: %{reply: "A billing specialist will answer within a day."}
  def shipping(_state), do: %{reply: "Our shipping team is checking your order."}
end

{:ok, state} = MyApp.TicketTriage.invoke(%{subject: "Refund for order A-1001"})
state.reply
#=> "A billing specialist will answer within a day."
```

`classify` sets `category`, the edge whose `when:` matches sends the ticket to
`billing`, and the run ends after it. The result is the final state.

## Build and run a graph

`BeamWeaver.Graph` builds a graph one call at a time: `Graph.new/1` starts an
empty graph, `Graph.add_node/4` adds a node (a name and a function), and
`Graph.add_edge/3` connects two nodes. `Graph.start()` and `Graph.end_node()`
mark where a run begins and where it finishes.

In an application, use `graph do` as above. Inside the block, `start()` and
`finish()` mark its boundaries, `node` adds a function, and `edge` determines
what can run next. A `state do` block declares channels; `join` waits for
multiple branches. See [Graph State](graph_state.md).

For a graph whose structure is computed from data, return the builder from
`def graph` in a module with `use BeamWeaver.Graph`. Choose one definition
style per module: declaring nodes and defining `graph/0` together is an error. The module gets
`invoke/2`, `stream_events/2`, `resume/2` and `get_state/1`, the same
functions an agent module has, and compiles the graph on each call with that
call's options, such as its checkpointer.

In a script or a test, or when the shape of the graph comes from data, compile
the builder with `Graph.compile!/2` and run it with
`BeamWeaver.Graph.Compiled.invoke/3`:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

triage =
  Graph.new()
  |> Graph.add_node(:classify, &MyApp.TicketTriage.classify/1)
  |> Graph.add_edge(Graph.start(), :classify)
  |> Graph.add_edge(:classify, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(triage, %{subject: "Where is order A-1001?"})
#=> {:ok, %{subject: "Where is order A-1001?", category: :shipping}}
```

`Graph.compile/2` returns `{:ok, compiled}` or `{:error, error}` instead of
raising. The examples below use compiled graphs to stay short; every builder
pipeline works the same inside `def graph`.

## Nodes

A node is a function that takes the state and returns a map of the keys it
changes. BeamWeaver merges that map into the state; keys the node leaves out
keep their values. A node can take a second argument, the
`BeamWeaver.Graph.Runtime`, which carries the per-call `context:`, the
`config:` and a stream writer:

```elixir
greet = fn state, runtime ->
  %{greeting: "Hi #{runtime.context.customer}, about order #{state.order_id}:"}
end

greeter =
  Graph.new()
  |> Graph.add_node(:greet, greet)
  |> Graph.add_edge(Graph.start(), :greet)
  |> Graph.add_edge(:greet, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(greeter, %{order_id: "A-1001"}, context: %{customer: "Ada"})
state.greeting
#=> "Hi Ada, about order A-1001:"
```

Besides a map, a node can return `nil` (no change), a
[`Command`](#update-and-route-with-command), a list of
[`Send`](#map-reduce-with-send) structs, or `{:error, reason}` to fail. A
failed node is retried and handled as its [options](#node-options) say, and
then the run returns the error: a `BeamWeaver.Core.Error` as it is, any other
reason as an error of type `:node_error`, with a string reason as its
message. If a node raises, the run returns
`{:error, %BeamWeaver.Core.Error{type: :node_exception}}`.

```elixir
lookup = fn _state -> {:error, "order service unavailable"} end

failing =
  Graph.new()
  |> Graph.add_node(:lookup, lookup)
  |> Graph.add_edge(Graph.start(), :lookup)
  |> Graph.add_edge(:lookup, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(failing, %{})
#=> {:error, %BeamWeaver.Core.Error{type: :node_error, message: "order service unavailable"}}
```

### Node options

`Graph.add_node/4` takes options for the node:

| Option | What it does |
| --- | --- |
| `retry:` | Runs the node again when it fails, such as `[max_attempts: 3, initial_delay: 200]` (see `BeamWeaver.RetryPolicy`). |
| `timeout:` | Milliseconds one attempt of the node may run; no limit by default. |
| `error_handler:` | `fn error, state, runtime -> update end`, called when the node still fails after its retries. |
| `cache:` | Reuses the result for the same input, such as `[ttl: 60_000]`; see [Caching](caching.md). |
| `deps:` | Nodes that must finish first; see [Parallel branches and joins](#parallel-branches-and-joins). |
| `input:`, `output:` | Reshape the state the node sees and the update it returns; see [Subgraphs](subgraphs.md). |
| `destinations:` | The nodes a `Command` or `Send` may go to, for graph drawings and [static checks](#validate-a-graph). |

An option a node doesn't take, such as `retry_policy:` for `retry:`, makes
`Graph.compile/2` return an `:invalid_graph` error naming it, so a typo can't
switch a setting off unnoticed.

A node that calls an outside service usually needs `retry:`, `timeout:` and
`error_handler:`; [Durable Execution](durable_execution.md) shows each of them
at work.

## Edges and routing

An edge runs one node after another. Add `when:` to take the edge only when the
update the first node returned matches; mark one edge `default: true` to take it
when no `when:` matched. `when:` takes a map whose keys must all match, with
literals, lists of allowed values, ranges or one-argument functions as values,
such as `%{priority: [:high, :urgent], amount: 0..100}`. It also takes a
function of the update, `fn update -> ... end`, or of the update and the whole
state, `fn update, state -> ... end`.

```elixir
refunds =
  Graph.new()
  |> Graph.add_node(:check_refund, fn %{amount: amount} -> %{large: amount > 100} end)
  |> Graph.add_node(:auto_approve, fn _state -> %{decision: :approved} end)
  |> Graph.add_node(:manager_review, fn _state -> %{decision: :needs_manager} end)
  |> Graph.add_edge(Graph.start(), :check_refund)
  |> Graph.add_edge(:check_refund, :manager_review, when: %{large: true})
  |> Graph.add_edge(:check_refund, :auto_approve, default: true)
  |> Graph.add_edge(:auto_approve, Graph.end_node())
  |> Graph.add_edge(:manager_review, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(refunds, %{amount: 250})
state.decision
#=> :needs_manager
```

Every edge whose `when:` matches is taken, and their targets run in parallel.
When nothing matches and there is no default, the run ends after that node.
A `when:` function that raises fails the run with
`{:error, %BeamWeaver.Core.Error{type: :edge_exception}}`, whose
`details.node` names the node the edge leaves.

### Loops

An edge can point back to an earlier node. `max_runs:` limits how many times
one run takes a guarded edge; after that, the default edge wins:

```elixir
drafting =
  Graph.new()
  |> Graph.add_reducer(:drafts, &+/2)
  |> Graph.add_node(:draft, fn _state -> %{drafts: 1} end)
  |> Graph.add_node(:review, fn _state -> %{verdict: :revise} end)
  |> Graph.add_node(:escalate, fn _state -> %{escalated: true} end)
  |> Graph.add_edge(Graph.start(), :draft)
  |> Graph.add_edge(:draft, :review)
  |> Graph.add_edge(:review, :draft, when: %{verdict: :revise}, max_runs: 2)
  |> Graph.add_edge(:review, :escalate, default: true)
  |> Graph.add_edge(:escalate, Graph.end_node())

Compiled.invoke(Graph.compile!(drafting), %{drafts: 0})
#=> {:ok, %{drafts: 3, verdict: :revise, escalated: true}}
```

The reviewer never accepts here, so the graph drafts three times, the first
draft and two revisions, then escalates. `Graph.add_reducer/3` makes `drafts`
add up instead of being replaced; see [Graph State](graph_state.md).

The count belongs to the run. On a thread, every new run may take the edge
`max_runs` times again, while a run that continues where the thread stopped,
after an interrupt, a failure or `Compiled.update_state/4`, keeps its count:

```elixir
drafting = Graph.compile!(drafting, checkpointer: BeamWeaver.Checkpoint.ETS.new())
thread = [config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, %{drafts: 3}} = Compiled.invoke(drafting, %{drafts: 0}, thread)
Compiled.invoke(drafting, %{drafts: 0}, thread)
#=> {:ok, %{drafts: 6, verdict: :revise, escalated: true}}
```

## Update and route with Command

When the node itself decides where to go, return a
`%BeamWeaver.Graph.Command{}`. Its `update` is merged into the state and its
`goto` names the next node, a list of nodes, or `Graph.end_node()`. A `goto`
replaces the node's own edges:

```elixir
alias BeamWeaver.Graph.Command

route = fn %{subject: subject} ->
  category = if subject =~ ~r/refund/i, do: :billing, else: :shipping
  %Command{update: %{category: category}, goto: category}
end

router =
  Graph.new()
  |> Graph.add_node(:classify, route, destinations: [:billing, :shipping])
  |> Graph.add_node(:billing, &MyApp.TicketTriage.billing/1)
  |> Graph.add_node(:shipping, &MyApp.TicketTriage.shipping/1)
  |> Graph.add_edge(Graph.start(), :classify)
  |> Graph.add_edge(:billing, Graph.end_node())
  |> Graph.add_edge(:shipping, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(router, %{subject: "Where is order A-1001?"})
state.reply
#=> "Our shipping team is checking your order."
```

Use guarded edges when the rule belongs to the shape of the graph, and a
`Command` when choosing the next step is part of the node's work.

## Parallel branches and joins

Several edges out of one node start parallel branches. Their nodes run at the
same time, each in its own process, and their updates are merged when all of
them finish. Two branches that write the same key in the same step need a
[reducer](graph_state.md#reducers) for that key.

`Graph.add_join/4` runs a node once, after every node in a list has finished,
however many steps each branch takes. Here the history branch has two nodes
and the order branch one:

```elixir
lookup_order = fn %{order_id: id} -> %{order_status: "#{id} shipped on Monday"} end
check_history = fn _state -> %{ticket_ids: ["T-7", "T-9"]} end
count_open = fn %{ticket_ids: ids} -> %{open_tickets: length(ids)} end
reply = fn state -> %{reply: "#{state.order_status}; #{state.open_tickets} open tickets."} end

parallel =
  Graph.new()
  |> Graph.add_node(:lookup_order, lookup_order)
  |> Graph.add_node(:check_history, check_history)
  |> Graph.add_node(:count_open, count_open)
  |> Graph.add_node(:reply, reply)
  |> Graph.add_edge(Graph.start(), :lookup_order)
  |> Graph.add_edge(Graph.start(), :check_history)
  |> Graph.add_edge(:check_history, :count_open)
  |> Graph.add_join([:lookup_order, :count_open], :reply)
  |> Graph.add_edge(:reply, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(parallel, %{order_id: "A-1001"})
state.reply
#=> "A-1001 shipped on Monday; 2 open tickets."
```

The node option `deps: [:lookup_order, :count_open]` on `:reply` declares
the same join. A join remembers which branches have arrived, and that is saved
with the thread's checkpoints, so it also fires when a branch finishes in a
later run, such as after an interrupt or a failed step, and it survives
`Compiled.update_state/4`. An update made `as_node:` a branch's last node
counts as that branch arriving.

## Map-reduce with Send

When the number of parallel tasks is known only at run time, return a list of
`%BeamWeaver.Graph.Send{}` structs. Each one runs its `node` once, on the
state merged with its `update`. A reducer collects the results, and an edge
after the worker node runs once, when all the workers are done:

```elixir
alias BeamWeaver.Graph.Send

split = fn %{order_ids: ids} ->
  Enum.map(ids, &%Send{node: :check_order, update: %{order_id: &1}})
end

check_order = fn %{order_id: id} -> %{statuses: ["#{id}: shipped"]} end
summarize = fn %{statuses: statuses} -> %{summary: Enum.join(statuses, ", ")} end

map_reduce =
  Graph.new()
  |> Graph.add_reducer(:statuses, &(&1 ++ &2))
  |> Graph.add_node(:split, split)
  |> Graph.add_node(:check_order, check_order)
  |> Graph.add_node(:summarize, summarize)
  |> Graph.add_edge(Graph.start(), :split)
  |> Graph.add_edge(:check_order, :summarize)
  |> Graph.add_edge(:summarize, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(map_reduce, %{order_ids: ["A-1001", "A-1002"], statuses: []})
state.summary
#=> "A-1001: shipped, A-1002: shipped"
```

A `Command` can carry sends too: `%Command{update: ..., goto: [%Send{...}]}`.
[Workflow Patterns](workflow_patterns.md#orchestrator-workers) builds an
orchestrator and its workers this way.

## Call a model or an agent from a node

A node is ordinary Elixir, so it can call a chat model or run a whole agent.
Here the support agent answers the ticket:

```elixir
alias BeamWeaver.Core.Message

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Your order A-1001 shipped on Monday."]
  system_prompt "You are Acme's support agent."
end

answer = fn %{subject: subject} ->
  {:ok, result} = MyApp.SupportAgent.invoke(%{messages: [subject]})
  %{reply: result.messages |> List.last() |> Message.text()}
end

assisted =
  Graph.new()
  |> Graph.add_node(:answer, answer, timeout: 120_000)
  |> Graph.add_edge(Graph.start(), :answer)
  |> Graph.add_edge(:answer, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(assisted, %{subject: "Where is my order A-1001?"})
state.reply
#=> "Your order A-1001 shipped on Monday."
```

Nodes have no time limit by default. A `timeout:`, as here, makes a model or
agent call that hangs fail the node instead of holding up the run. To call a chat model, build it
once, outside the node, with `BeamWeaver.Models.init_chat_model!/2`, and call
`BeamWeaver.Core.ChatModel.invoke/3` inside; every example in
[Workflow Patterns](workflow_patterns.md) works this way. To run an agent as
part of the graph, with its checkpoints, interrupts and events in the same
run, add the agent module itself as a node instead,
`Graph.add_node(graph, :answer, MyApp.SupportAgent)`; see
[Subgraphs](subgraphs.md#agents-as-subgraphs).

## Stream a run

`stream_events/2` with `live: true` returns a stream of typed events while the
graph runs (`BeamWeaver.Graph.Compiled.stream_events/3` for a compiled graph);
without `live: true` it returns the same events as a list when the run ends.
A `GraphUpdate` event carries the update of each node that finished:

```elixir
alias BeamWeaver.Stream.Events

{:ok, events} = MyApp.TicketTriage.stream_events(%{subject: "Refund for order A-1001"}, live: true)

for %{event: %Events.GraphUpdate{update: update}} <- events, do: Map.keys(update)
#=> [["classify"], ["billing"]]
```

Inside a node, `runtime.stream_writer.(payload)` emits your own `Custom`
events, such as progress for a long step. [Streaming](streaming.md) lists the
event types and shows how to send them to a LiveView.

## Interrupts

`BeamWeaver.Graph.interrupt/2` pauses the run inside a node and hands a value
to the caller. To resume later, the run needs a checkpointer. Resume with an
answer: the node runs again from its start, and this time `interrupt/2`
returns the answer.

```elixir
defmodule MyApp.RefundApproval do
  use BeamWeaver.Graph

  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_node(:approve, &approve/1)
    |> Graph.add_node(:refund, &refund/1)
    |> Graph.add_edge(Graph.start(), :approve)
    |> Graph.add_edge(:approve, :refund, when: %{approved: true})
    |> Graph.add_edge(:refund, Graph.end_node())
  end

  def approve(%{order_id: order_id, amount: amount}) do
    answer = Graph.interrupt(%{question: "Refund $#{amount} for order #{order_id}?"})
    %{approved: answer == "yes"}
  end

  def refund(%{order_id: order_id}), do: %{reply: "Refund issued for order #{order_id}."}
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:interrupted, interrupt} = MyApp.RefundApproval.invoke(%{order_id: "A-1001", amount: 40}, opts)
interrupt.value
#=> %{question: "Refund $40 for order A-1001?"}
```

```elixir
{:ok, state} = MyApp.RefundApproval.resume("yes", opts)
state.reply
#=> "Refund issued for order A-1001."
```

Because the node starts over on resume, do side effects after the interrupt,
not before. [Human-in-the-Loop](human_in_the_loop.md#pause-a-graph-node)
covers the rules for pausing a node and answering several pauses at once.
Pass `response_schema:` to describe the answer a client should send and check
it on resume; see [Check the answer](human_in_the_loop.md#check-the-answer).

To pause before or after a node without changing its code, declare
`interrupt_before` or `interrupt_after` with node names (a compiled graph
takes them as `Graph.compile!/2` options). `resume/2` with `nil` continues the
run past the pause:

```elixir
defmodule MyApp.CheckedRefund do
  use BeamWeaver.Graph

  alias BeamWeaver.Graph

  interrupt_before [:refund]

  def graph do
    Graph.new()
    |> Graph.add_node(:refund, &refund/1)
    |> Graph.add_edge(Graph.start(), :refund)
    |> Graph.add_edge(:refund, Graph.end_node())
  end

  def refund(%{order_id: order_id}), do: %{reply: "Refund issued for order #{order_id}."}
end

checked = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-43"}}]
{:interrupted, %{timing: :before, nodes: ["refund"]}} = MyApp.CheckedRefund.invoke(%{order_id: "A-1002"}, checked)

{:ok, state} = MyApp.CheckedRefund.resume(nil, checked)
state.reply
#=> "Refund issued for order A-1002."
```

## Checkpoints

With a checkpointer, BeamWeaver saves the state of a thread after every step.
For a graph module, pass the saver and the thread id on each call, as above,
and read the latest state with `get_state/1`:

```elixir
{:ok, snapshot} = MyApp.RefundApproval.get_state(opts)
snapshot.values.reply
#=> "Refund issued for order A-1001."
```

A compiled graph takes its checkpointer when it compiles,
`Graph.compile!(graph, checkpointer: saver)`, and the thread id with each
call. [Checkpoints and Time Travel](checkpoints.md) shows history, replay and
forks; [Durable Execution](durable_execution.md) shows how a run continues
after a crash.

## Recursion limit

A run proceeds in steps: in each step, every node that is ready runs, in
parallel. A run may take at most 25 steps by default, so a graph that loops
forever stops with an error instead:

```elixir
poller =
  Graph.new()
  |> Graph.add_node(:poll, fn %{polls: polls} -> %{polls: polls + 1} end)
  |> Graph.add_edge(Graph.start(), :poll)
  |> Graph.add_edge(:poll, :poll)
  |> Graph.compile!()

Compiled.invoke(poller, %{polls: 0}, recursion_limit: 5)
#=> {:error, %BeamWeaver.Core.Error{type: :recursion_limit, details: %{limit: 5}}}
```

Pass `recursion_limit:` on a call, or declare `recursion_limit 50` in a graph
module to change its default. A node can read how many steps are left and
stop on its own; see [managed values](graph_state.md#managed-values).

## Validate a graph

`Graph.compile/2` checks a graph before it runs: every edge must point at a
node, there must be an edge from `Graph.start()`, and nodes and reducers must
have the right shape. `Graph.validation_report/2` lists every problem at once,
and `validate_static: true` also reports nodes that no edge reaches and nodes
that never lead to the end:

```elixir
broken =
  Graph.new()
  |> Graph.add_node(:classify, &MyApp.TicketTriage.classify/1)
  |> Graph.add_node(:escalate, fn _state -> %{escalated: true} end)
  |> Graph.add_edge(Graph.start(), :classify)
  |> Graph.add_edge(:classify, :reply)

report = Graph.validation_report(broken, validate_static: true)
Enum.map(report.diagnostics, &{&1.message, &1.details})
#=> [
#     {"graph references missing nodes", %{missing: ["reply"]}},
#     {"graph contains unreachable nodes", %{nodes: ["escalate"]}}
#   ]
```

A one-line test such as
`assert {:ok, _} = Graph.compile(MyApp.TicketTriage.graph(), validate_static: true)`
catches a broken graph before it ships. The checks can't see where a
`Command` or `Send` goes, so list those targets in the node's `destinations:`
and the checks follow them. The router from
[Update and route with Command](#update-and-route-with-command) passes:

```elixir
routed =
  Graph.new()
  |> Graph.add_node(:classify, route, destinations: [:billing, :shipping])
  |> Graph.add_node(:billing, &MyApp.TicketTriage.billing/1)
  |> Graph.add_node(:shipping, &MyApp.TicketTriage.shipping/1)
  |> Graph.add_edge(Graph.start(), :classify)
  |> Graph.add_edge(:billing, Graph.end_node())
  |> Graph.add_edge(:shipping, Graph.end_node())

Graph.validation_report(routed, validate_static: true).diagnostics
#=> []
```

`BeamWeaver.Graph.Compiled.draw_mermaid/2` draws a compiled graph as a
Mermaid diagram for reviews and docs.

## Static graphs as modules

When the shape of a graph never changes, you can declare it with the
`graph do ... end` DSL instead of a builder pipeline. Each line is one builder
call: `node` adds a node, `edge` an edge (with the same `when:`, `default:` and
`max_runs:` options), `join` a join, `reducer` a reducer, and `state do` sets
how keys merge. `start()` and `finish()` are the start and end markers.

```elixir
defmodule MyApp.TicketTriage do
  use BeamWeaver.Graph

  graph do
    state do
      channel :notes, merge: :list
    end

    node :lookup_order, &lookup_order/1
    node :check_history, &check_history/1
    node :reply, &reply/1

    edge start(), :lookup_order
    edge start(), :check_history
    join [:lookup_order, :check_history], :reply
    edge :reply, finish()
  end

  def lookup_order(%{order_id: id}), do: %{order_status: "#{id} shipped on Monday", notes: ["found #{id}"]}
  def check_history(_state), do: %{open_tickets: 2, notes: ["read history"]}
  def reply(state), do: %{reply: "#{state.order_status}; #{state.open_tickets} open tickets."}
end

{:ok, state} = MyApp.TicketTriage.invoke(%{order_id: "A-1001"})
{state.reply, Enum.sort(state.notes)}
#=> {"A-1001 shipped on Monday; 2 open tickets.", ["found A-1001", "read history"]}
```

In `state do`, `merge:` is `:last` (the default, like a plain key), `:list`
(append, starting from `[]`), `:map` (`Map.merge/2`, starting from `%{}`) or a
two-argument function used as a [reducer](graph_state.md#reducers), and
`visibility: :private` makes a [private key](graph_state.md#private-keys). The
module runs like any graph module. Use the builder when the graph is built
from data at run time.

## Reference

- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): build, validate and compile graphs; `interrupt/2`; graph modules and their declarations
- [`BeamWeaver.Graph.Compiled`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Compiled.html): run a compiled graph: invoke, stream, resume, read state
- [`BeamWeaver.Graph.Command`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Command.html): update the state and choose the next node
- [`BeamWeaver.Graph.Send`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Send.html): run a node once per item
- [`BeamWeaver.Graph.Runtime`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Runtime.html): the second argument of a node
- [`BeamWeaver.RetryPolicy`](https://hexdocs.pm/beam_weaver/BeamWeaver.RetryPolicy.html): node retry options
