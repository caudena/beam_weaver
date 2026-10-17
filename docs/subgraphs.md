# Subgraphs

A subgraph is a compiled graph, or an agent, used as one node of another
graph. Use one to reuse a workflow in several graphs, to keep each part small
and testable on its own, or to run an agent as one step of a larger workflow
with its checkpoints, interrupts and events in the same run.

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

refund_check =
  Graph.new(name: "RefundCheck")
  |> Graph.add_node(:check_amount, fn %{amount: amount} -> %{refund_ok: amount <= 100} end)
  |> Graph.add_edge(Graph.start(), :check_amount)
  |> Graph.add_edge(:check_amount, Graph.end_node())
  |> Graph.compile!()

reply = fn %{refund_ok: ok} ->
  %{reply: if(ok, do: "Your refund is approved.", else: "A manager will review your refund.")}
end

triage =
  Graph.new()
  |> Graph.add_node(:refund_check, refund_check)
  |> Graph.add_node(:reply, reply)
  |> Graph.add_edge(Graph.start(), :refund_check)
  |> Graph.add_edge(:refund_check, :reply)
  |> Graph.add_edge(:reply, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(triage, %{order_id: "A-1001", amount: 40})
state.reply
#=> "Your refund is approved."
```

## Shared keys

When the parent and the subgraph use the same keys, add the compiled graph as
a node, as above. The subgraph starts from the parent's state and runs to its
end, and the keys it changed become the node's update. That is all
`refund_check` needs: it reads `amount` and writes `refund_ok`.

For a key with a [reducer](graph_state.md#reducers) in the parent, the update
holds only what the subgraph added, the new end of a list or the new entries
of a map, so the parent's reducer applies it once:

```elixir
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

Any other change to such a key, such as an `Overwrite` or a removed message,
replaces the parent's value. A subgraph with an `input_schema:` receives only
those keys, and one with an `output_schema:` passes back only those.

Shared keys suit small subgraphs that work on the parent's own data. When the
subgraph has keys of its own, map the state in and out instead.

## Map state in and out

`input:` decides what the subgraph receives and `output:` what the parent gets
back. Here the parent keeps the order in a nested map and names the result
differently:

```elixir
refunds =
  Graph.new()
  |> Graph.add_node(:refund_check, refund_check,
    input: fn %{order: order} -> %{amount: order.total} end,
    output: fn %{refund_ok: ok} -> %{approved: ok} end
  )
  |> Graph.add_edge(Graph.start(), :refund_check)
  |> Graph.add_edge(:refund_check, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(refunds, %{order: %{id: "A-1001", total: 250}})
#=> {:ok, %{order: %{id: "A-1001", total: 250}, approved: false}}
```

| Option | Value | Effect |
| --- | --- | --- |
| `input:` | a list of keys | The subgraph receives only those keys. |
| `input:` | `fn state -> map end` | The subgraph receives the map the function returns. |
| `output:` | an atom | The parent stores the subgraph's final state under that key. |
| `output:` | `fn result -> update end` | The parent merges the update the function returns. |

The same options work on any node, not only subgraphs.

## Agents as subgraphs

An agent module can be a node too: add the module, and each time the node runs
the agent's graph runs as a subgraph. Here the parent maps its ticket to the
agent's `messages` and the agent's last message back to a reply:

```elixir
alias BeamWeaver.Core.Message

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Your order A-1001 shipped on Monday."]
  system_prompt "You are Acme's support agent."
end

desk =
  Graph.new()
  |> Graph.add_node(:support, MyApp.SupportAgent,
    input: fn %{ticket: ticket} -> %{messages: [ticket]} end,
    output: fn %{messages: messages} -> %{reply: messages |> List.last() |> Message.text()} end,
    timeout: 120_000
  )
  |> Graph.add_edge(Graph.start(), :support)
  |> Graph.add_edge(:support, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(desk, %{ticket: "Where is my order A-1001?"})
state.reply
#=> "Your order A-1001 shipped on Monday."
```

The agent's tools, middleware and interrupts all run inside the `support`
node, and its declarations are read each time it runs. Nodes have no time
limit by default; if you give the agent node a `timeout:`, leave it enough
time for a whole agent run. When the parent keeps the conversation in a `messages` key of
its own, with `BeamWeaver.Graph.Messages.state_schema/1`, leave out `input:`
and `output:`: the agent reads the conversation, and its new messages are
added to it. A graph module works the same way, and
`BeamWeaver.Agent.compiled_graph/2` returns an agent's compiled graph when you
need it as a value.

You can also call `Compiled.invoke/3` or `MyApp.SupportAgent.invoke/2` from an
ordinary node function. That is simpler, but the call is a separate run: its
checkpoints, interrupts and events don't become part of the parent's run.

## Checkpoint namespaces

A subgraph saves its checkpoints with the parent's checkpointer, under its own
namespace in the same thread. The subgraph's `checkpointer:` compile option
decides how:

| `checkpointer:` | Behaviour |
| --- | --- |
| left out | Each call starts fresh, under a namespace such as `"notes:<task id>"`. |
| `true` | The node keeps one namespace, `"notes"`, so its state carries over between calls on the same thread. |
| `false` | The subgraph saves no checkpoints. |
| a saver | The subgraph uses its own storage. |

Here the `notes` subgraph remembers every note taken on the thread:

```elixir
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

The thread's history holds checkpoints for both graphs, told apart by
`checkpoint_ns`:

```elixir
history = Compiled.get_state_history(desk, config)

history
|> Enum.map(&get_in(&1.config, ["configurable", "checkpoint_ns"]))
|> Enum.uniq()
|> Enum.sort()
#=> ["", "notes"]
```

Don't run the same `checkpointer: true` subgraph twice in parallel on one
thread: both runs would write to the same namespace.
[Checkpoints and Time Travel](checkpoints.md) shows how to read and replay
history.

## Interrupts in a subgraph

An interrupt inside a subgraph pauses the whole run. The parent returns
`{:interrupted, interrupt}`, and you resume through the parent, which resumes
the subgraph where it stopped:

```elixir
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

```elixir
Compiled.resume(refund_desk, "yes", config: config)
#=> {:ok, %{amount: 40, approved: true, refunded: true}}
```

A subgraph that pauses in several nodes at once pauses the parent with all
of them: `interrupt.interrupts` and `get_state/1` on the parent list each
pause. Answer them with a map from interrupt id to answer, all at once or one
at a time, as for
[several pauses in one graph](human_in_the_loop.md#several-pauses-at-once).

While the subgraph waits, the parent's state can change: other nodes of the
same step finish, `Compiled.update_state/4` edits it, or the `Command` that
resumes the run carries an `update`. The subgraph still resumes where it
stopped, with the state it had, and its update holds only what it changed,
so those changes stay:

```elixir
paused = %{"configurable" => %{"thread_id" => "ticket-44"}}
{:interrupted, _interrupt} = Compiled.invoke(refund_desk, %{amount: 40}, config: paused)
{:ok, _config} = Compiled.update_state(refund_desk, paused, %{note: "Customer called back."})

Compiled.resume(refund_desk, "yes", config: paused)
#=> {:ok, %{amount: 40, note: "Customer called back.", approved: true, refunded: true}}
```

To change what the paused subgraph itself sees, edit its own state: pass
its namespace from the thread's history as `checkpoint_ns` to
`Compiled.update_state/4` on the parent graph. The subgraph resumes with the
edit, and since it changed `amount`, its update carries the new value back
to the parent:

```elixir
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

[Human-in-the-Loop](human_in_the_loop.md) covers interrupts in detail.

## Jump to a parent node

A node inside a subgraph can route the parent: return a `Command` with
`graph: Command.parent()`, and its `goto` names a node of the parent graph:

```elixir
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

Like any `goto`, it replaces the subgraph node's own edges: the `:auto` edge
is not taken.

## Stream a subgraph

A subgraph's events arrive in the parent's stream. Each event envelope has a
`namespace`: `[]` for the parent, and the path of node names for a subgraph,
such as `["refund_check"]`:

```elixir
{:ok, events} = Compiled.stream_events(triage, %{amount: 40}, live: true)

events |> Enum.map(& &1.namespace) |> Enum.uniq() |> Enum.sort()
#=> [[], ["refund_check"]]
```

Nested subgraphs get longer paths, such as `["middle", "inner"]`. See
[Streaming](streaming.md) for the event types. A subgraph that fails sends no
`Error` event of its own; [Streaming](streaming.md#subgraphs) shows how to
tell how each subgraph ended.

## Reference

- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): `add_node/4` with `input:` and `output:`
- [`BeamWeaver.Graph.Compiled`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Compiled.html): run graphs and read their history
- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): `compiled_graph/2` turns an agent into a graph
- [`BeamWeaver.Graph.Command`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Command.html): `parent/0` routes the parent graph
- [`BeamWeaver.Stream.Envelope`](https://hexdocs.pm/beam_weaver/BeamWeaver.Stream.Envelope.html): event envelopes and their `namespace`
