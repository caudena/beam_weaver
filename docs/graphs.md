# Graph DSL

Use a graph when your application decides the workflow: fixed steps,
conditional branches, parallel checks or a review loop. Use an agent when
the model should choose its own actions. A graph can contain model calls,
agents and other graphs.

This first example is ordinary Elixir and needs no provider credentials.
Run the blocks in order in IEx after installing BeamWeaver.

## Build and run a graph

```elixir
defmodule MyApp.TicketRouter do
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

  def classify(%{subject: subject}),
    do: %{category: if(subject =~ ~r/refund/i, do: :billing, else: :shipping)}

  def billing(_state), do: %{queue: "billing"}
  def shipping(_state), do: %{queue: "shipping"}
end

{:ok, state} = MyApp.TicketRouter.invoke(%{subject: "Refund for order A-1001"})
"billing" = state.queue
"Refund for order A-1001" = state.subject
```

`graph do` describes the topology; node functions do the work. `start()` and
`finish()` are boundary markers, not application nodes. The module supplies
`invoke/2`, `stream_events/2`, `resume/2`, `get_state/1` and `compiled_graph/1`.
Definitions are built/compiled with each call's options. Storage must be
owned outside the invocation, just as for [agents](agents.md).

## Nodes

A node receives state and returns only changed keys. Unchanged keys remain.
A two-argument node also receives `BeamWeaver.Graph.Runtime` with context,
configuration, execution metadata and a custom-event writer.

| Return | Effect |
| --- | --- |
| A map | Merge changed keys through their channels |
| `nil` | Keep state unchanged |
| `Graph.Command` | Update state and choose a destination |
| A list of `Graph.Send` values | Dispatch dynamic work |
| `{:error, reason}` | Fail the node |

A `Core.Error` propagates as an error; other reasons normalize to
`:node_error`. Raised exceptions become `:node_exception`. Return an error
rather than inventing success when an external dependency fails.

### Node options

| Option | Purpose |
| --- | --- |
| `timeout:` | Milliseconds for one attempt; unlimited by default |
| `retry:` | Retry policy for node failure |
| `error_handler:` | Recovery after retry exhaustion |
| `cache:` | Cache results through configured cache storage |
| `input:`, `output:` | Map the node's state boundary |
| `deps:` | Wait for named prerequisite nodes |
| `destinations:` | Declare dynamic routing targets for validation/drawing |

Unknown options fail compilation. [Durable Execution](durable_execution.md)
explains retries and timeouts; [Caching](caching.md) covers cache keys.

A node can combine input state with trusted runtime context:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

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

Return a tagged error when the action fails:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

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

## Edges and routing

An edge runs a destination after its source. `when:` normally examines the
**source update**, not the entire accumulated state. Use a two-argument
predicate to inspect both update and state. Map guards support literal values,
allowed-value lists, ranges and predicates.

All matching guarded edges run; this can create parallel branches. A default
edge runs only if none match. Without a match or default, that path ends.
An exception in a predicate becomes `:edge_exception`.

### Loops

Back-edges create loops. `max_runs:` bounds traversal of a guarded edge and
then lets a default route handle the exhausted case. Counts belong to one
run and survive continuation; a new run resets them. Always distinguish
"accepted" from "revision budget exhausted" in final state.

This workflow routes a large amount to review:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

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

This local reviewer always requests revision, so the bounded loop reaches escalation:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

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

The same saved thread retains accumulated state; the next invocation gets a new traversal budget:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

drafting = Graph.compile!(drafting, checkpointer: BeamWeaver.Checkpoint.ETS.new())
thread = [config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, %{drafts: 3}} = Compiled.invoke(drafting, %{drafts: 0}, thread)
Compiled.invoke(drafting, %{drafts: 0}, thread)
#=> {:ok, %{drafts: 6, verdict: :revise, escalated: true}}
```

## Parallel branches and joins

Branches execute in the same superstep and merge their updates after finishing.
Use reducers when several branches write the same key. A `join` waits for all
listed branches, even when they take different numbers of steps:

```elixir
defmodule MyApp.OrderChecks do
  use BeamWeaver.Graph

  graph do
    state do
      channel :checks, merge: :map
    end

    node :order, fn _state -> %{checks: %{order_exists: true}} end
    node :policy, fn %{amount: amount} -> %{checks: %{within_limit: amount <= 100}} end
    node :decide, fn %{checks: checks} -> %{eligible: checks.order_exists and checks.within_limit} end

    edge start(), :order
    edge start(), :policy
    join [:order, :policy], :decide
    edge :decide, finish()
  end
end

{:ok, checked} = MyApp.OrderChecks.invoke(%{amount: 40})
%{order_exists: true, within_limit: true} = checked.checks
true = checked.eligible
```

These are local example checks, not a payment policy. `deps:` on a node is
an alternative way to declare its join. Join arrivals are checkpointed so
completed branches still count after another branch pauses or fails.

## Update and route with Command

`%Graph.Command{update: changes, goto: destination}` combines data and control
flow. `goto` can be a node, a list, sends, or the end marker. It replaces the
returning node's ordinary outgoing edges. Declare possible targets in
`destinations:` for static validation. Use a command when destination selection
belongs inside the node; use guarded edges when it belongs to the topology.

This node returns both the category and the next destination:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Graph.Command

route = fn %{subject: subject} ->
  category = if subject =~ ~r/refund/i, do: :billing, else: :shipping
  %Command{update: %{category: category}, goto: category}
end

router =
  Graph.new()
  |> Graph.add_node(:classify, route, destinations: [:billing, :shipping])
  |> Graph.add_node(:billing, fn _ -> %{reply: "Our billing team is checking your refund."} end)
  |> Graph.add_node(:shipping, fn _ -> %{reply: "Our shipping team is checking your order."} end)
  |> Graph.add_edge(Graph.start(), :classify)
  |> Graph.add_edge(:billing, Graph.end_node())
  |> Graph.add_edge(:shipping, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(router, %{subject: "Where is order A-1001?"})
state.reply
#=> "Our shipping team is checking your order."
```

## Map-reduce with Send

Use `Send` when the number of tasks is known only at runtime:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.{Compiled, Send}

batch =
  Graph.new()
  |> Graph.add_reducer(:results, &Kernel.++/2)
  |> Graph.add_node(
    :dispatch,
    fn %{values: values} ->
      Enum.map(values, &%Send{node: :double, update: %{value: &1}})
    end,
    destinations: [:double]
  )
  |> Graph.add_node(:double, fn %{value: value} -> %{results: [value * 2]} end)
  |> Graph.add_node(:total, fn %{results: results} -> %{total: Enum.sum(results)} end)
  |> Graph.add_edge(Graph.start(), :dispatch)
  |> Graph.add_edge(:double, :total)
  |> Graph.add_edge(:total, Graph.end_node())
  |> Graph.compile!()

{:ok, reduced} = Compiled.invoke(batch, %{values: [2, 3, 5], results: []})
[4, 6, 10] = Enum.sort(reduced.results)
20 = reduced.total
```

Each send runs the worker with state plus its update. Worker results merge
through reducers; the following node runs after that batch. Do not depend
on completion order when order is not part of the task contract.

## Static graphs as modules

Inside `graph do`, use `node`, `edge`, `join`, `reducer` and `state do`.
A state `channel` can use `merge: :last`, `:list`, `:map` or a reducer function,
plus visibility options. [Graph State](graph_state.md) explains channels.

Use the builder (`Graph.new`, `add_node`, `add_edge`, `add_join`) for topology
computed from data. A graph module can return that builder from `graph/0`
instead of declaring nodes. Choose one style per module. A compiled value
runs through `BeamWeaver.Graph.Compiled`; a module runs through its generated
functions.

## Call a model or an agent from a node

A node can call `ChatModel.invoke/3` and return the reply as an update. Model
initialization creates a value; network work happens at invocation. Set a
node timeout that accommodates the provider timeout and retries.

Adding an agent module as the node makes it a subgraph with integrated
checkpoints, interrupts and events. Calling `Agent.invoke` inside a plain
function creates a separate run. See [Subgraphs](subgraphs.md#agents-as-subgraphs)
and the real-model [Workflow Patterns](workflow_patterns.md).

## Batch independent runs

`Compiled.batch/3` returns sequential outcomes in input order.
`batch_as_completed/3` returns a lazy concurrent stream with input indices;
set max concurrency and task timeouts. Keep independent thread IDs for
concurrent runs. `bulk_update_state/4` is a different operation: it applies
checkpointed supersteps of state edits without executing business nodes.

For independent inputs, consume the indexed completion stream and correlate results by index:

```elixir
{:ok, router} = MyApp.TicketRouter.compiled_graph([])
inputs = [%{subject: "Refund A-1001"}, %{subject: "Delivery A-1002"}]
[{:ok, %{queue: "billing"}}, {:ok, %{queue: "shipping"}}] = BeamWeaver.Graph.Compiled.batch(router, inputs)
{:ok, completions} = BeamWeaver.Graph.Compiled.batch_as_completed(router, inputs, max_concurrency: 2)
completed = Enum.to_list(completions)
true = length(completed) == 2
IO.inspect(completed, label: "Results with input indices")
```

## Stream a run

`stream_events/2` reports typed events; `live: true` makes it lazy.
Consume once, handle failures and correlate subgraph namespaces.
Nodes emit custom progress through `runtime.stream_writer`.
[Streaming](streaming.md) covers lifecycle and cancellation.

## Interrupts

Call `Graph.interrupt/2` inside a node or configure static before/after
breakpoints. Both need a checkpointer for continuation. Dynamic interrupt
nodes rerun from the beginning on resume, so earlier side effects can repeat.
See [Human Review](human_in_the_loop.md#pause-a-graph-node).

## Checkpoints

Graph modules accept storage and thread configuration per invocation.
Compiled graphs take the saver at compilation and thread configuration per
call. A checkpoint preserves values and pending execution, not arbitrary
process state. [Checkpoints](checkpoints.md) explains inspection and replay.

## Recursion limit

A superstep runs all currently ready nodes. The default graph budget is 25
steps; reaching it returns `:recursion_limit`. Set a per-call or declared
budget. `RemainingSteps` and `IsLastStep` managed values let nodes choose a
controlled exit before exhaustion.

An unbounded polling edge is stopped by the run budget:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

poller =
  Graph.new()
  |> Graph.add_node(:poll, fn %{polls: polls} -> %{polls: polls + 1} end)
  |> Graph.add_edge(Graph.start(), :poll)
  |> Graph.add_edge(:poll, :poll)
  |> Graph.compile!()

Compiled.invoke(poller, %{polls: 0}, recursion_limit: 5)
#=> {:error, %BeamWeaver.Core.Error{type: :recursion_limit, details: %{limit: 5}}}
```

## Validate a graph

`Graph.compile/2` returns a result tuple; `compile!/2` raises.
`validation_report/2` reports all detected problems. With `validate_static: true`,
validation also checks reachability and paths to an end. Dynamic routing is
visible only when destinations are declared.

```elixir
%{diagnostics: []} = Graph.validation_report(MyApp.TicketRouter.graph(), validate_static: true)
{:ok, compiled} = MyApp.TicketRouter.compiled_graph([])
diagram = Compiled.draw_mermaid(compiled)
true = is_binary(diagram) and byte_size(diagram) > 0
```

Static validity does not prove external services or node business rules work.
Exercise representative inputs and failure paths in your application tests.
