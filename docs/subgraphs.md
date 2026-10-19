# Subgraphs

A graph or agent can be one node of a larger graph. Use this to compose
workflows while preserving nested events, checkpoints and interrupts.
Choose an explicit state boundary so one component does not accidentally
write another's internal data.

## Map state in and out

This model-free example nests an eligibility check:

```elixir
defmodule MyApp.Eligibility do
  use BeamWeaver.Graph

  graph do
    node :check, fn %{amount: amount} -> %{eligible: amount > 0 and amount <= 100} end
    edge start(), :check
    edge :check, finish()
  end
end

alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

workflow =
  Graph.new()
  |> Graph.add_node(:eligibility, MyApp.Eligibility,
    input: fn %{order: order} -> %{amount: order.total} end,
    output: fn %{eligible: eligible} -> %{eligible: eligible} end
  )
  |> Graph.add_edge(Graph.start(), :eligibility)
  |> Graph.add_edge(:eligibility, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(workflow, %{order: %{id: "A-1001", total: 40}})
true = state.eligible
%{id: "A-1001", total: 40} = state.order
false = Map.has_key?(state, :amount)
```

`input:` accepts a key list or mapping function. `output:` accepts a function
returning the parent update, or an atom under which to store the child result.
These mappings also work for ordinary nodes.

## Shared keys

Without mappings, the child reads parent state and returns the changes it
made. For list/map reducer keys, additive changes are applied once rather
than re-appending the entire inherited value. Overwrites and removals instead
replace the relevant parent value. Child input/output schemas further restrict
which keys cross the boundary.

Shared state is convenient for small components with the same contract.
Mappings make reusable components easier to evolve and prevent incidental
state from becoming a public dependency.

The child contributes one note; the inherited note is not appended a second time:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

review =
  Graph.new(name: "Review")
  |> Graph.add_reducer(:notes, &(&1 ++ &2))
  |> Graph.add_node(:review, fn %{amount: amount} -> %{notes: ["reviewed $#{amount}"]} end)
  |> Graph.add_edge(Graph.start(), :review)
  |> Graph.add_edge(:review, Graph.end_node())
  |> Graph.compile!()

ticket =
  Graph.new()
  |> Graph.add_reducer(:notes, &(&1 ++ &2))
  |> Graph.add_node(:review, review)
  |> Graph.add_edge(Graph.start(), :review)
  |> Graph.add_edge(:review, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(ticket, %{amount: 40, notes: ["opened by Ada"]})
#=> {:ok, %{amount: 40, notes: ["opened by Ada", "reviewed $40"]}}
```

## Agents as subgraphs

After [Installation](installation.md), an agent can perform the writing step
using a real OpenAI model and supplied facts:

```elixir
defmodule MyApp.ExplainDecision do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Explain the supplied eligibility result briefly. Do not claim a refund was executed."
end

with_agent =
  Graph.new()
  |> Graph.add_node(:explain, MyApp.ExplainDecision,
    input: fn %{eligible: eligible} -> %{messages: ["Eligibility check result: #{eligible}."]} end,
    output: fn %{messages: messages} -> %{explanation: messages |> List.last() |> BeamWeaver.Core.Message.text()} end,
    timeout: 90_000
  )
  |> Graph.add_edge(Graph.start(), :explain)
  |> Graph.add_edge(:explain, Graph.end_node())
  |> Graph.compile!()

{:ok, explained} = Compiled.invoke(with_agent, %{eligible: true})
true = byte_size(explained.explanation) > 0
```

The agent's full loop runs inside that node. Size the node timeout for all
model/tool turns and retries. Both graph and agent modules implement the graph
behavior through `compiled_graph/1`.

Calling `Agent.invoke` or `Compiled.invoke` inside a plain node function is
also possible, but creates a separate run. Its interrupts and checkpoints do
not automatically become the parent's nested execution.

## Checkpoint namespaces

Child checkpoint behavior is selected when compiling the child:

| Child `checkpointer:` | Behavior |
| --- | --- |
| Omitted | Fresh task-specific namespace using the parent's saver |
| `true` | Stable node namespace, retaining child state across thread calls |
| `false` | No child checkpoint persistence |
| A saver | Explicit child storage |

The parent still needs a saver for durable orchestration. Do not run a
stateful `checkpointer: true` child concurrently against the same thread and
namespace without application coordination. Inspect `checkpoint_ns` in
history to distinguish parent and child snapshots.

A stable child namespace retains its own notes over two parent calls:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

notes =
  Graph.new(name: "Notes")
  |> Graph.add_reducer(:notes, &(&1 ++ &2))
  |> Graph.add_node(:take_note, fn %{subject: subject} -> %{notes: [subject]} end)
  |> Graph.add_edge(Graph.start(), :take_note)
  |> Graph.add_edge(:take_note, Graph.end_node())
  |> Graph.compile!(checkpointer: true)

saver = BeamWeaver.Checkpoint.ETS.new()
config = %{"configurable" => %{"thread_id" => "ticket-42"}}

desk =
  Graph.new()
  |> Graph.add_node(:notes, notes,
    input: [:subject],
    output: fn %{notes: notes} -> %{ticket_notes: notes} end
  )
  |> Graph.add_edge(Graph.start(), :notes)
  |> Graph.add_edge(:notes, Graph.end_node())
  |> Graph.compile!(checkpointer: saver)

{:ok, _state} = Compiled.invoke(desk, %{subject: "Where is A-1001?"}, config: config)
{:ok, state} = Compiled.invoke(desk, %{subject: "Refund for A-1001"}, config: config)
state.ticket_notes
#=> ["Where is A-1001?", "Refund for A-1001"]
```

History identifies the parent and stable child namespaces:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

history = Compiled.get_state_history(desk, config)

history
|> Enum.map(&get_in(&1.config, ["configurable", "checkpoint_ns"]))
|> Enum.uniq()
|> Enum.sort()

#=> ["", "notes"]
```

## Interrupts in a subgraph

A child interrupt pauses the parent. Resume through the parent with the same
thread/checkpointer and fresh context. Parallel child pauses are exposed in
`interrupt.interrupts`; answer by interrupt ID.

While a child waits, the parent may receive other state updates. The child
resumes its own saved state and returns only its changes, preserving unrelated
parent updates. To edit the child itself, select its checkpoint namespace
when updating state. [Checkpoints](checkpoints.md) and
[Human Review](human_in_the_loop.md) cover those operations.

Create a child that asks for approval, then invoke its parent:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

approval =
  Graph.new(name: "Approval")
  |> Graph.add_node(:ask, fn %{amount: amount} ->
    %{approved: Graph.interrupt(%{question: "Refund $#{amount}?"}) == "yes"}
  end)
  |> Graph.add_edge(Graph.start(), :ask)
  |> Graph.add_edge(:ask, Graph.end_node())
  |> Graph.compile!()

refund_desk =
  Graph.new()
  |> Graph.add_node(:approval, approval)
  |> Graph.add_node(:refund, fn %{approved: approved} -> %{refunded: approved} end)
  |> Graph.add_edge(Graph.start(), :approval)
  |> Graph.add_edge(:approval, :refund)
  |> Graph.add_edge(:refund, Graph.end_node())
  |> Graph.compile!(checkpointer: saver)

config = %{"configurable" => %{"thread_id" => "ticket-43"}}
{:interrupted, interrupt} = Compiled.invoke(refund_desk, %{amount: 40}, config: config)
interrupt.value
#=> %{question: "Refund $40?"}
```

Resume through the parent:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

Compiled.resume(refund_desk, "yes", config: config)
#=> {:ok, %{amount: 40, approved: true, refunded: true}}
```

An unrelated parent edit survives child continuation:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

paused = %{"configurable" => %{"thread_id" => "ticket-44"}}
{:interrupted, _interrupt} = Compiled.invoke(refund_desk, %{amount: 40}, config: paused)
{:ok, _config} = Compiled.update_state(refund_desk, paused, %{note: "Customer called back."})

Compiled.resume(refund_desk, "yes", config: paused)
#=> {:ok, %{amount: 40, note: "Customer called back.", approved: true, refunded: true}}
```

To change the child input itself, select its saved namespace:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

edited = %{"configurable" => %{"thread_id" => "ticket-45"}}
{:interrupted, _interrupt} = Compiled.invoke(refund_desk, %{amount: 40}, config: edited)

namespace =
  refund_desk
  |> Compiled.get_state_history(edited)
  |> Enum.map(&get_in(&1.config, ["configurable", "checkpoint_ns"]))
  |> Enum.find(&String.starts_with?(&1, "approval:"))

subgraph = put_in(edited, ["configurable", "checkpoint_ns"], namespace)
{:ok, _config} = Compiled.update_state(refund_desk, subgraph, %{amount: 50})

Compiled.resume(refund_desk, "yes", config: edited)
#=> {:ok, %{amount: 50, approved: true, refunded: true}}
```

## Jump to a parent node

A child can return `Graph.Command` with `graph: Command.parent()` and a `goto`
naming a parent node. Declare that destination on the parent's child node for
static validation. The jump replaces the node's ordinary outgoing route.
Use explicit escalation paths rather than assuming the parent will infer
what a child result means.

Amounts above the local threshold jump directly to the parent manager node:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Graph.Command

escalate = fn %{amount: amount} ->
  if amount > 100, do: %Command{graph: Command.parent(), goto: :manager}, else: %{}
end

escalation =
  Graph.new(name: "Escalation")
  |> Graph.add_node(:check, escalate)
  |> Graph.add_edge(Graph.start(), :check)
  |> Graph.add_edge(:check, Graph.end_node())
  |> Graph.compile!()

routing =
  Graph.new()
  |> Graph.add_node(:escalation, escalation, destinations: [:manager])
  |> Graph.add_node(:manager, fn _state -> %{handled_by: :manager} end)
  |> Graph.add_node(:auto, fn _state -> %{handled_by: :auto} end)
  |> Graph.add_edge(Graph.start(), :escalation)
  |> Graph.add_edge(:escalation, :auto)
  |> Graph.add_edge(:manager, Graph.end_node())
  |> Graph.add_edge(:auto, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(routing, %{amount: 250})
#=> {:ok, %{amount: 250, handled_by: :manager}}
```

## Stream a subgraph

Events carry the path of nested node names in `namespace`; parent events use
`[]`. A child failure first fails its parent node, whose retry/error handler
may recover it. Only an unrecovered run failure produces the terminal `Error`.
`Stream.Subgraphs.from_events/2` summarizes nested outcomes from task events.

Consume once and inspect the namespaces from the nested eligibility workflow defined at the start of this page:

```elixir
{:ok, events} = BeamWeaver.Graph.Compiled.stream_events(workflow, %{order: %{id: "A-1001", total: 40}}, live: true)
namespaces = events |> Enum.map(& &1.namespace) |> Enum.uniq()
true = [] in namespaces
true = Enum.any?(namespaces, &(&1 != []))
IO.inspect(namespaces)
```
