# State and Channels

Every graph has one state map. Nodes return updates, and each key's channel
decides how to apply them. Start with ordinary keys; add a reducer when several
nodes contribute to one value. A graph needs no model unless its nodes call one.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Declare how state merges

Run this complete graph in IEx:

```elixir
defmodule MyApp.ReviewState do
  use BeamWeaver.Graph

  graph do
    state do
      channel :notes, merge: :list
      channel :checks, merge: :map
    end

    node :order, fn _state -> %{notes: ["Order checked"], checks: %{order: true}} end
    node :policy, fn _state -> %{notes: ["Policy checked"], checks: %{policy: true}} end
    edge start(), :order
    edge start(), :policy
    edge :order, finish()
    edge :policy, finish()
  end
end

{:ok, state} = MyApp.ReviewState.invoke(%{})
["Order checked", "Policy checked"] = Enum.sort(state.notes)
%{order: true, policy: true} = state.checks
```

Both nodes write in the same step. List and map reducers merge those writes.
A plain key uses `LastValue` and accepts one write per step; multiple writes
fail with `:invalid_update` instead of choosing an accidental winner.

## Updates replace values

Return only changed keys. Unwritten values remain. An ordinary key's update
replaces its value; nested maps are not recursively merged unless you choose
that reducer. Returning full state from every parallel branch creates needless
write conflicts and can attempt to update managed values.

Two branches writing one ordinary key produce an explicit conflict:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Core.Message
alias BeamWeaver.Graph.Channels.LastValue

clash =
  Graph.new()
  |> Graph.add_node(:fraud_check, fn _state -> %{status: "clear"} end)
  |> Graph.add_node(:policy_check, fn _state -> %{status: "auto-approve"} end)
  |> Graph.add_edge(Graph.start(), :fraud_check)
  |> Graph.add_edge(Graph.start(), :policy_check)
  |> Graph.add_edge(:fraud_check, Graph.end_node())
  |> Graph.add_edge(:policy_check, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(clash, %{})
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_update, details: %{channel: :status}}}
```

## Reducers

`Graph.add_reducer(graph, key, function)` installs a two-argument reducer:
current value plus one write. List append, `Map.merge/2`, sum and maximum are
common choices. Supply initial state when the reducer requires it; an empty
key's first write becomes its value directly.

Prefer associative operations for parallel aggregation. If order matters,
include an explicit position in each result and sort after collecting.
`:list` and `:map` DSL channels provide empty initial collections.

Use separate reducers for the map and the count:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Core.Message
alias BeamWeaver.Graph.Channels.LastValue

review =
  Graph.new()
  |> Graph.add_reducer(:checks, &Map.merge/2)
  |> Graph.add_reducer(:checks_run, &+/2)
  |> Graph.add_node(:fraud_check, fn _state -> %{checks: %{fraud: :clear}, checks_run: 1} end)
  |> Graph.add_node(:policy_check, fn _state -> %{checks: %{policy: :ok}, checks_run: 1} end)
  |> Graph.add_edge(Graph.start(), :fraud_check)
  |> Graph.add_edge(Graph.start(), :policy_check)
  |> Graph.add_edge(:fraud_check, Graph.end_node())
  |> Graph.add_edge(:policy_check, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(review, %{checks: %{}, checks_run: 0})
#=> {:ok, %{checks: %{fraud: :clear, policy: :ok}, checks_run: 2}}
```

## Messages

Conversation state needs ID-aware merging rather than ordinary list append:

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

chat =
  Graph.new(state_schema: Graph.Messages.state_schema())
  |> Graph.add_node(:reply, fn _state -> %{messages: [Message.assistant("Which order should I check?")]} end)
  |> Graph.add_edge(Graph.start(), :reply)
  |> Graph.add_edge(:reply, Graph.end_node())
  |> Graph.compile!()

{:ok, conversation} = Compiled.invoke(chat, %{messages: ["Hello"]})
[:user, :assistant] = Enum.map(conversation.messages, & &1.role)
true = Enum.all?(conversation.messages, &is_binary(&1.id))
```

`Graph.Messages.state_schema/1` normalizes messages, appends new IDs and
replaces existing IDs. `remove/1` deletes a known message ID; an unknown ID is
an invalid update. `remove_all/0` resets history before new messages are added.
Agents already use this message-aware channel.

Remove a message by its assigned ID:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Core.Message
alias BeamWeaver.Graph.Channels.LastValue

forget =
  Graph.new(state_schema: BeamWeaver.Graph.Messages.state_schema())
  |> Graph.add_node(:forget, fn %{messages: [first | _rest]} ->
    %{messages: [BeamWeaver.Graph.Messages.remove(first.id)]}
  end)
  |> Graph.add_edge(Graph.start(), :forget)
  |> Graph.add_edge(:forget, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(forget, %{messages: ["My card is 4111 1111.", "Refund order A-1001"]})
Enum.map(state.messages, &Message.text/1)
#=> ["Refund order A-1001"]
```

## Channels

Use `Graph.channel/2` in `state_schema:` or `add_channel/4` in the builder for
specialized behavior. Function-based channels use `{module, function}`.

| Channel | Behavior | Typical use |
| --- | --- | --- |
| `LastValue` | One write per step | Ordinary state |
| `BinaryOperatorAggregate` | Fold writes with a reducer | Lists, maps, totals |
| `Topic` | Collect step writes; `accumulate: true` retains prior steps | Event collections |
| `AnyValue` | Accept multiple writes, retain the last | Values whose writers agree |
| `EphemeralValue` | Keep a write for the next step | Short-lived signals |
| `UntrackedValue` | Keep a run-local value without checkpointing | Clients or transient handles |
| `DeltaChannel` | Reconstruct values from recorded writes | Growing histories |

Non-accumulating topics and ephemeral values clear after the following step
unless written again. Untracked data must be supplied again after recovery.
Delta writes and their `prepare:` transformation must be replay-safe:
preparing an already-prepared write must not change it. Message delta channels
assign stable IDs before persistence.

An accumulating topic records each step while the numeric channel sums amounts:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Core.Message
alias BeamWeaver.Graph.Channels.LastValue

alias BeamWeaver.Graph.Channels.{BinaryOperatorAggregate, Topic}

audit =
  Graph.new(
    state_schema: %{
      events: Graph.channel(Topic, accumulate: true),
      refunded: Graph.channel({BinaryOperatorAggregate, &+/2}, initial: 0)
    }
  )
  |> Graph.add_node(:refund, fn _state -> %{events: "refunded $40", refunded: 40} end)
  |> Graph.add_node(:notify, fn _state -> %{events: "emailed Ada"} end)
  |> Graph.add_edge(Graph.start(), :refund)
  |> Graph.add_edge(:refund, :notify)
  |> Graph.add_edge(:notify, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(audit, %{})
#=> {:ok, %{events: ["refunded $40", "emailed Ada"], refunded: 40}}
```

## Overwrite a reducer

Use `Graph.Overwrite` for an intentional replacement:

```elixir
reset =
  Graph.new()
  |> Graph.add_reducer(:notes, &Kernel.++/2)
  |> Graph.add_node(:close, fn _ -> %{notes: Graph.Overwrite.new(["Closed"])} end)
  |> Graph.add_edge(Graph.start(), :close)
  |> Graph.add_edge(:close, Graph.end_node())
  |> Graph.compile!()

{:ok, %{notes: ["Closed"]}} = Compiled.invoke(reset, %{notes: ["Opened", "Reviewed"]})
```

One overwrite is allowed per key per step; it supersedes other writes to that
key in the same step. Make that precedence deliberate.

## Private keys

`Graph.private_channel/2` exposes data to nodes but excludes it from ordinary
output and, by default, checkpoints. `checkpoint: true` keeps private
bookkeeping across thread calls while still hiding it from the output.

Private is a visibility convention, not encryption or tenant isolation.
Do not put nonserializable handles in checkpointed channels. Agent tools using
generic state injection omit private keys; explicit key injection can access them.

Nodes can use the score, but the caller receives only the public decision:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Core.Message
alias BeamWeaver.Graph.Channels.LastValue

alias BeamWeaver.Graph.Channels.LastValue

scoring =
  Graph.new(state_schema: %{risk_score: Graph.private_channel(LastValue)})
  |> Graph.add_node(:score, fn _state -> %{risk_score: 0.12} end)
  |> Graph.add_node(:decide, fn %{risk_score: score} ->
    %{decision: if(score < 0.5, do: :approve, else: :review)}
  end)
  |> Graph.add_edge(Graph.start(), :score)
  |> Graph.add_edge(:score, :decide)
  |> Graph.add_edge(:decide, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(scoring, %{})
#=> {:ok, %{decision: :approve}}
```

## Keys that start nodes

A channel's `subscribers:` schedules named nodes when that key is written.
This is data-driven scheduling without an explicit edge. Keep subscriptions
visible in the workflow design so a state update cannot unexpectedly trigger
an external action. Ordinary retry and idempotency rules still apply.

Writing the alert schedules its subscriber:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Core.Message
alias BeamWeaver.Graph.Channels.LastValue

alerts =
  Graph.new(state_schema: %{alert: Graph.channel(LastValue, subscribers: [:notify_manager])})
  |> Graph.add_node(:check_refund, fn %{amount: amount} ->
    if amount > 100, do: %{alert: "Large refund: $#{amount}"}, else: %{}
  end)
  |> Graph.add_node(:notify_manager, fn %{alert: alert} -> %{notified: alert} end)
  |> Graph.add_edge(Graph.start(), :check_refund)
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(alerts, %{amount: 250})
state.notified
#=> "Large refund: $250"
```

## Managed values

`Graph.managed(RemainingSteps)` and `Graph.managed(IsLastStep)` supply runtime
budget information to nodes. Managed values are read-only and not saved.
Use them to return a controlled partial result before hitting the recursion
limit. A write to a managed key fails.

Use the remaining budget to stop a polling loop deliberately:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Core.Message
alias BeamWeaver.Graph.Channels.LastValue

alias BeamWeaver.Graph.Managed.RemainingSteps

polling =
  Graph.new(state_schema: %{remaining_steps: Graph.managed(RemainingSteps)})
  |> Graph.add_reducer(:polls, &+/2)
  |> Graph.add_node(:poll_carrier, fn state -> %{polls: 1, stop: state.remaining_steps <= 2} end)
  |> Graph.add_node(:give_up, fn state -> %{status: "no news after #{state.polls} polls"} end)
  |> Graph.add_edge(Graph.start(), :poll_carrier)
  |> Graph.add_edge(:poll_carrier, :give_up, when: %{stop: true})
  |> Graph.add_edge(:poll_carrier, :poll_carrier, default: true)
  |> Graph.add_edge(:give_up, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(polling, %{polls: 0}, recursion_limit: 5)
state.status
#=> "no news after 4 polls"
```

## Input and output schemas

Graph `input_schema:` and `output_schema:` define the keys crossing the graph
boundary. Undeclared keys are filtered; schema descriptions also support
`Compiled.get_input_json_schema/1` and `get_output_json_schema/1`.
They are not a substitute for validating domain values in your nodes.

Only the declared output crosses the graph boundary:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

alias BeamWeaver.Core.Message
alias BeamWeaver.Graph.Channels.LastValue

triage =
  Graph.new(input_schema: %{subject: :string}, output_schema: %{reply: :string})
  |> Graph.add_node(:classify, fn %{subject: subject} ->
    %{category: if(subject =~ ~r/refund/i, do: :billing, else: :shipping)}
  end)
  |> Graph.add_node(:reply, fn %{category: category} -> %{reply: "Routed to the #{category} queue."} end)
  |> Graph.add_edge(Graph.start(), :classify)
  |> Graph.add_edge(:classify, :reply)
  |> Graph.add_edge(:reply, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(triage, %{subject: "Refund for order A-1001", debug: true})
#=> {:ok, %{reply: "Routed to the billing queue."}}
```

## UI state

`BeamWeaver.Graph.UI` stores component-name/props messages in an ID-aware
channel. New IDs append; existing IDs replace (or merge props when requested);
removal markers delete. Runtime push/delete helpers emit UI events and return
data for a node update. They do not provide a frontend renderer or persist
state merely by emitting an event. Your client owns allowed components and
safe rendering of props.

Push a component description and include it in the node update. A later write with the same ID updates its props:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.{Compiled, UI}

flow =
  Graph.new(state_schema: UI.state_schema())
  |> Graph.add_node(:show, fn _state, runtime ->
    {:ok, card} = UI.push_ui_message(runtime, "order-card", %{status: "checking"}, id: "order-A-1001")
    %{ui: [card]}
  end)
  |> Graph.add_node(:update, fn _ ->
    %{ui: [UI.message("order-card", %{status: "shipped"}, id: "order-A-1001", merge: true)]}
  end)
  |> Graph.add_edge(Graph.start(), :show)
  |> Graph.add_edge(:show, :update)
  |> Graph.add_edge(:update, Graph.end_node())
  |> Graph.compile!()

{:ok, result} = Compiled.invoke(flow, %{})
[%{id: "order-A-1001", props: %{status: "shipped"}}] = result.ui
[] = UI.reducer(result.ui, [UI.remove("order-A-1001")])
```

## Which one to use

Choose a plain key for one writer, a reducer for combined results, the message
channel for conversations, a private channel for hidden bookkeeping and an
untracked channel for data that must never be restored from storage.
[Subgraphs](subgraphs.md) explains how updates cross nested state boundaries.
