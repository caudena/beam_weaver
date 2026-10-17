# Graph State

Every graph run reads and writes one state map, and each node returns only the
keys it changes; by default a write replaces the key's value. Give a key a
reducer or a channel when writes should add up, when parallel nodes write the
same key, or when a key should stay out of the result.

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

refund_checks =
  Graph.new()
  |> Graph.add_reducer(:flags, &(&1 ++ &2))
  |> Graph.add_node(:fraud_check, fn _state -> %{flags: ["fraud: clear"]} end)
  |> Graph.add_node(:policy_check, fn %{amount: amount} ->
    %{flags: ["policy: #{if amount <= 100, do: "auto-approve", else: "ask a manager"}"]}
  end)
  |> Graph.add_edge(Graph.start(), :fraud_check)
  |> Graph.add_edge(Graph.start(), :policy_check)
  |> Graph.add_edge(:fraud_check, Graph.end_node())
  |> Graph.add_edge(:policy_check, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(refund_checks, %{amount: 40, flags: []})
Enum.sort(state.flags)
#=> ["fraud: clear", "policy: auto-approve"]
```

Both checks run in the same step and write `flags`; the reducer appends both
writes instead of failing.

## Updates replace values

A node returns a map of the keys it changes. A write replaces the key's value,
and keys that nobody writes keep theirs. Two nodes may not write the same plain
key in the same step, because BeamWeaver can't tell which write should win:

```elixir
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

Write different keys, or give the key a reducer.

## Reducers

`Graph.add_reducer/3` gives a key a function of two arguments. BeamWeaver calls
it with the current value and each write, in order, and stores the result. The
first write to an empty key is stored as it is, so pass a starting value in
the input when the reducer needs one.

| To | Reducer |
| --- | --- |
| Append to a list | `&(&1 ++ &2)` |
| Merge maps | `&Map.merge/2` |
| Add up numbers | `&+/2` |
| Keep the largest | `&max/2` |

```elixir
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

For a conversation, use `BeamWeaver.Graph.Messages.state_schema/1`. Its
`messages` key appends new messages, turns plain strings into user messages,
and replaces a message that has the same id:

```elixir
alias BeamWeaver.Core.Message

chat =
  Graph.new(state_schema: BeamWeaver.Graph.Messages.state_schema())
  |> Graph.add_node(:greet, fn _state -> %{messages: [Message.assistant("Hi Ada! Which order?")]} end)
  |> Graph.add_edge(Graph.start(), :greet)
  |> Graph.add_edge(:greet, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(chat, %{messages: ["Hello"]})
Enum.map(state.messages, &{&1.role, Message.text(&1)})
#=> [{:user, "Hello"}, {:assistant, "Hi Ada! Which order?"}]
```

To delete a message, write `BeamWeaver.Graph.Messages.remove/1` with its id:

```elixir
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

Removing an id that isn't in the list fails the run with an
`:invalid_update` error. Agents keep their conversation in a key like this
one. [Messages](messages.md) describes the message struct.

## Channels

Behind every key is a channel, which decides how writes merge. A plain key uses
`LastValue`, and `Graph.add_reducer/3` creates a `BinaryOperatorAggregate`.
Choose another channel with `Graph.add_channel/4`, or declare keys up front with
`Graph.new(state_schema: %{key => Graph.channel(channel, opts)})`. Each
channel is a module, such as `BeamWeaver.Graph.Channels.Topic`:

| Channel | Merges the writes of a step by | Use it for |
| --- | --- | --- |
| `LastValue` | keeping the only write; two writes fail | most keys (the default) |
| `BinaryOperatorAggregate` | folding them through a function; `initial:` sets the start | totals, lists, maps |
| `Topic` | collecting them into a list, which lasts one step; `accumulate: true` keeps every step's writes | events from several nodes |
| `AnyValue` | keeping the last one, without failing on several | a value parallel branches agree on |
| `EphemeralValue` | keeping the only write for one step | a signal for the next node only |
| `UntrackedValue` | keeping the value for the run but never checkpointing it | clients, handles, large scratch data |
| `DeltaChannel` | calling its function with the list of writes; checkpoints store only the writes | long lists that only grow |

```elixir
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

A `Topic` without `accumulate:` and an `EphemeralValue` hold what one step
wrote: the nodes of the next step read it, and it is cleared after that step
unless a node writes it again.

A `DeltaChannel` rebuilds its value from the writes saved in earlier
checkpoints whenever a thread is read, so a write must read back the same
every time. Its `prepare:` option takes a function that prepares each write
before it is applied, streamed or saved; a prepared write can go through it
again and must come back unchanged. `BeamWeaver.Graph.Messages.delta_channel/1`
uses it to give each message its id once.

A channel that needs a function takes a `{module, function}` tuple. The same
forms work with `Graph.add_channel/4`:
`Graph.add_channel(graph, :refunded, {BinaryOperatorAggregate, &+/2}, initial: 0)`.
A [graph module](graphs.md#static-graphs-as-modules) declares its channels in
`state do` with `merge: :last | :list | :map | reducer`.

## Overwrite a reducer

Wrap a write in `BeamWeaver.Graph.Overwrite` to replace the value without
calling the reducer, for example to reset a list:

```elixir
alias BeamWeaver.Graph.Overwrite

notes =
  Graph.new()
  |> Graph.add_reducer(:notes, &(&1 ++ &2))
  |> Graph.add_node(:call_carrier, fn _state -> %{notes: ["called the carrier"]} end)
  |> Graph.add_node(:close, fn _state -> %{notes: Overwrite.new(["ticket closed"])} end)
  |> Graph.add_edge(Graph.start(), :call_carrier)
  |> Graph.add_edge(:call_carrier, :close)
  |> Graph.add_edge(:close, Graph.end_node())
  |> Graph.compile!()

Compiled.invoke(notes, %{notes: ["opened by Ada"]})
#=> {:ok, %{notes: ["ticket closed"]}}
```

A key accepts one overwrite per step, and the overwrite drops the step's other
writes to the key.

## Private keys

A private channel is visible to nodes but left out of the result and out of
checkpoints. Use it for intermediate values that callers should not see:

```elixir
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

`Graph.add_channel(graph, :risk_score, LastValue, visibility: :private)` does
the same. For bookkeeping that belongs to a thread rather than a run,
`Graph.private_channel(LastValue, checkpoint: true)` still keeps the key out
of the result but saves it in checkpoints, so the next run on the thread
starts from its value.

## Keys that start nodes

A channel's `subscribers:` option runs those nodes whenever the key is
written, without an edge:

```elixir
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

A managed value is a key the runtime fills in for each node. Nodes can read
it but not write it, and it is never saved.
`BeamWeaver.Graph.Managed.RemainingSteps` holds the number of steps left before
the [recursion limit](graphs.md#recursion-limit), and
`BeamWeaver.Graph.Managed.IsLastStep` whether this is the last one. A loop can
use them to stop cleanly instead of failing:

```elixir
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

With a limit of five steps, the fourth poll sees two steps left and hands over
to `give_up`, which uses the last step. Writing to a managed key fails the run.

## Input and output schemas

`input_schema:` and `output_schema:` on `Graph.new/1` name the keys a graph
accepts and returns. Other input keys are dropped, and the result keeps only
the output keys. BeamWeaver filters by the keys; the values describe them for
`BeamWeaver.Graph.Compiled.get_input_json_schema/1` and
`BeamWeaver.Graph.Compiled.get_output_json_schema/1`.

```elixir
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

## Which one to use

| You want | Use |
| --- | --- |
| A value that one node sets | a plain key |
| Results of parallel nodes in one list | `&(&1 ++ &2)`, or `merge: :list` in a module |
| Results of parallel nodes by name | `&Map.merge/2`, or `merge: :map` in a module |
| A running total | `&+/2` |
| A conversation | `BeamWeaver.Graph.Messages.state_schema/1` |
| To reset a key that has a reducer | `Overwrite` |
| Intermediate data callers shouldn't see | `Graph.private_channel/2` |
| A connection or handle that can't be saved | `UntrackedValue` |
| A signal only the next node reads | `EphemeralValue` |
| The number of steps left | `Graph.managed(RemainingSteps)` |

[Workflow Patterns](workflow_patterns.md) puts these keys to work in graphs
that call models.

## Reference

- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): `add_reducer/3`, `add_channel/4`, `channel/2`, `private_channel/2`, `managed/2`
- [`BeamWeaver.Graph.Messages`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Messages.html): a `messages` key for conversations
- [`BeamWeaver.Graph.Overwrite`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Overwrite.html): replace a value without its reducer
- [`BeamWeaver.Graph.Channels.LastValue`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Channels.LastValue.html): the default channel
- [`BeamWeaver.Graph.Channels.BinaryOperatorAggregate`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Channels.BinaryOperatorAggregate.html): reducer channel
- [`BeamWeaver.Graph.Channels.Topic`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Channels.Topic.html): collect writes into a list
- [`BeamWeaver.Graph.Channels.UntrackedValue`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Channels.UntrackedValue.html): values that are never checkpointed
- [`BeamWeaver.Graph.Channels.EphemeralValue`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Channels.EphemeralValue.html): values that last one step
- [`BeamWeaver.Graph.Channel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Channel.html): behaviour for writing your own channel
- [`BeamWeaver.Graph.Managed.RemainingSteps`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Managed.RemainingSteps.html): steps left before the recursion limit
