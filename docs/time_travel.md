# Time Travel

Time travel lets you continue a graph from a prior checkpoint. Use it to replay
past execution, fork state, debug a branch, or rerun later nodes after changing
intermediate state.

BeamWeaver supports two time-travel patterns:

- **Replay**: continue from an older checkpoint config. Nodes before the
  checkpoint are not re-executed; nodes after it run again.
- **Fork**: create a new checkpoint from an older checkpoint with modified
  state, then continue from the returned config.

Both require a graph compiled with a checkpointer and a stable `thread_id`.

{% hint style="info" %}
**BeamWeaver Shape**

LangGraph's Python examples use `graph.invoke(None, checkpoint_config)`,
`Command(resume=...)`, tuple `StateSnapshot.next` values, and
`get_state(config, subgraphs=True)`. BeamWeaver uses
`BeamWeaver.Graph.Compiled.invoke/3` with `%{}` as the empty continuation input,
`BeamWeaver.Graph.Compiled.resume/3` for interrupted checkpoints, list-shaped
`snapshot.next`, and checkpoint namespace configs from `get_state_history/3`.
{% endhint %}

## Setup

This two-step graph is used throughout the guide:

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "time-travel-1"}}

graph =
  Graph.new(name: "JokeFlow")
  |> Graph.add_node(:generate_topic, fn _state ->
    %{topic: "socks in the dryer"}
  end)
  |> Graph.add_node(:write_joke, fn state ->
    %{joke: "Why do #{state.topic} disappear? They elope!"}
  end)
  |> Graph.add_edge(:generate_topic, :write_joke)
  |> Graph.add_edge(Graph.start(), :generate_topic)
  |> Graph.add_edge(:write_joke, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

{:ok, result} =
  Compiled.invoke(graph, %{}, config: config)
```

State history is newest first:

```elixir
history =
  Compiled.get_state_history(graph, config)

for snapshot <- history do
  IO.inspect(
    {snapshot.next, get_in(snapshot.config, ["configurable", "checkpoint_id"])},
    label: "checkpoint"
  )
end
```

## Replay

Replay from a prior checkpoint by invoking the graph with that checkpoint's
config and an empty input update:

```elixir
before_joke =
  Enum.find(history, fn snapshot ->
    snapshot.next == ["write_joke"]
  end)

{:ok, replayed} =
  Compiled.invoke(graph, %{}, config: before_joke.config)
```

`generate_topic` does not run again because its output is already in the
checkpoint. `write_joke` runs again because it is scheduled in `snapshot.next`.

{% hint style="warning" %}
**Replay Re-Executes Work**

Replay is not a cache read. Any node after the checkpoint runs again, including
LLM calls, API calls, tool calls, side effects, and interrupts. Replaying from a
final checkpoint whose `next` list is empty is a no-op.
{% endhint %}

When replaying side-effecting workflows, use idempotency keys, dedupe records,
or human review before external writes.

## Fork

Forking creates a new checkpoint from a prior checkpoint. It does not mutate or
roll back the original history.

```elixir
{:ok, fork_config} =
  Compiled.update_state(
    graph,
    before_joke.config,
    %{topic: "chickens"},
    as_node: :generate_topic
  )

{:ok, forked} =
  Compiled.invoke(graph, %{}, config: fork_config)

forked.joke
#=> "Why do chickens disappear? They elope!"
```

The original thread history remains intact. The fork appears as a new
checkpoint whose parent is the older checkpoint you selected.

{% hint style="info" %}
**Forks Share A Thread Unless You Copy**

`update_state/4` creates a branch inside the checkpoint history addressed by
the provided config. If your product needs a completely separate user-visible
thread, copy or clone checkpoint records at the adapter/application layer and
use a new `thread_id`.
{% endhint %}

## From A Specific Node

`update_state/4` applies values using the same channel merge logic as a node
write. When a key has a reducer, the update accumulates. Otherwise, the update
overwrites the current channel value.

BeamWeaver usually infers the node that produced the update from checkpoint
metadata. Pass `as_node:` when inference is ambiguous or when you intentionally
want the graph to resume from a specific node's successors:

```elixir
{:ok, fork_config} =
  Compiled.update_state(
    graph,
    before_joke.config,
    %{topic: "chickens"},
    as_node: :generate_topic
  )
```

Use `as_node:` when:

- multiple parallel nodes wrote in the same step
- you are creating state on a fresh or synthetic thread
- you want to skip a node by treating it as already completed
- you want reducers to apply as if a particular node produced the update

If BeamWeaver cannot infer the source node and you do not pass `as_node:`, it
returns a tagged `{:error, %BeamWeaver.Core.Error{type: :ambiguous_state_update}}`
instead of raising a Python `InvalidUpdateError`.

## Interrupts

Interrupts are re-triggered during time travel. The node containing
`BeamWeaver.Graph.interrupt/1` runs again and pauses for a new resume value.

```elixir
graph =
  Graph.new(name: "InterruptReplay")
  |> Graph.add_reducer(:value, fn existing, update ->
    List.wrap(existing) ++ List.wrap(update)
  end)
  |> Graph.add_node(:ask_human, fn _state ->
    answer = Graph.interrupt("What is your name?")
    %{value: ["Hello, #{answer}!"]}
  end)
  |> Graph.add_node(:final_step, fn _state ->
    %{value: ["Done"]}
  end)
  |> Graph.add_edge(:ask_human, :final_step)
  |> Graph.add_edge(Graph.start(), :ask_human)
  |> Graph.add_edge(:final_step, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

{:interrupted, first_interrupt} =
  Compiled.invoke(graph, %{value: []}, config: config)

{:ok, _state} =
  Compiled.resume(graph, "Alice", config: first_interrupt.config)

before_ask =
  graph
  |> Compiled.get_state_history(config)
  |> Enum.find(fn snapshot -> snapshot.next == ["ask_human"] end)

{:interrupted, replay_interrupt} =
  Compiled.invoke(graph, %{}, config: before_ask.config)

{:ok, replayed_state} =
  Compiled.resume(graph, "Bob", config: replay_interrupt.config)
```

Use the interrupt's returned `config` when resuming a replayed or forked
interrupt. That config carries the checkpoint target needed to continue the
right branch.

### Multiple Interrupts

If a graph collects human input at multiple points, fork between interrupts to
preserve earlier answers and re-ask later questions.

```elixir
graph =
  Graph.new(name: "FormFlow")
  |> Graph.add_reducer(:value, fn existing, update ->
    List.wrap(existing) ++ List.wrap(update)
  end)
  |> Graph.add_node(:ask_name, fn _state ->
    name = Graph.interrupt("What is your name?")
    %{value: ["name:#{name}"]}
  end)
  |> Graph.add_node(:ask_age, fn _state ->
    age = Graph.interrupt("How old are you?")
    %{value: ["age:#{age}"]}
  end)
  |> Graph.add_edge(:ask_name, :ask_age)
  |> Graph.add_edge(Graph.start(), :ask_name)
  |> Graph.add_edge(:ask_age, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

# After completing the original run, find the checkpoint between questions.
between_questions =
  graph
  |> Compiled.get_state_history(config)
  |> Enum.find(fn snapshot -> snapshot.next == ["ask_age"] end)

{:ok, fork_config} =
  Compiled.update_state(graph, between_questions.config, %{value: ["modified"]})

{:interrupted, age_interrupt} =
  Compiled.invoke(graph, %{}, config: fork_config)

{:ok, forked_state} =
  Compiled.resume(graph, 42, config: age_interrupt.config)
```

The earlier `ask_name` result remains in state. The later `ask_age` interrupt
fires again and accepts a new answer.

## Subgraphs

Subgraph time travel depends on the compiled subgraph's checkpoint scope.

| Subgraph Compile Option | BeamWeaver Behavior |
| --- | --- |
| `checkpointer: nil` or omitted | The child inherits the parent adapter and uses a task-scoped checkpoint namespace. Replaying from the parent checkpoint before the subgraph re-executes the child work. |
| `checkpointer: true` or `:shared` | The child uses the inherited adapter with a stable subgraph namespace. This is the best match for time travel inside a subgraph. |
| `checkpointer: false` or `:disabled` | The child does not checkpoint internally. Re-entering the parent starts the child fresh. |
| `checkpointer: adapter` | The child uses its own local checkpointer adapter. |

Parent-level replay looks like ordinary replay:

```elixir
before_subgraph =
  parent_graph
  |> Compiled.get_state_history(config)
  |> Enum.find(fn snapshot -> snapshot.next == ["subgraph"] end)

{:ok, replayed} =
  Compiled.invoke(parent_graph, %{}, config: before_subgraph.config)
```

To time travel inside a shared subgraph, compile the child with
`checkpointer: true`, then use the checkpoint namespace config from state
history:

```elixir
child =
  Graph.new(name: "Child")
  |> Graph.add_node(:step_a, step_a)
  |> Graph.add_node(:step_b, step_b)
  |> Graph.add_edge(:step_a, :step_b)
  |> Graph.add_edge(Graph.start(), :step_a)
  |> Graph.add_edge(:step_b, Graph.end_node())
  |> Graph.compile!(checkpointer: true)

parent_graph =
  Graph.new(name: "Parent")
  |> Graph.add_node(:subgraph, child)
  |> Graph.add_edge(Graph.start(), :subgraph)
  |> Graph.add_edge(:subgraph, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

inside_child =
  parent_graph
  |> Compiled.get_state_history(config)
  |> Enum.find(fn snapshot ->
    get_in(snapshot.config, ["configurable", "checkpoint_ns"]) == "subgraph" and
      snapshot.next == ["step_b"]
  end)

{:ok, fork_config} =
  Compiled.update_state(parent_graph, inside_child.config, %{value: ["forked"]})

{:ok, result} =
  Compiled.invoke(parent_graph, %{}, config: fork_config)
```

For nested shared subgraphs, checkpoint namespaces are path-like strings such as
`"outer/inner"`. The config also carries a `checkpoint_map` so the parent and
child checkpoints stay aligned when you replay or fork inside the nested graph.

{% hint style="info" %}
**No `subgraphs: true` State Option**

LangGraph's Python guide retrieves subgraph checkpoint configs with
`get_state(config, subgraphs=True)`. BeamWeaver exposes subgraph checkpoint
configs through `Compiled.get_state_history/3`; filter on
`config["configurable"]["checkpoint_ns"]` and `snapshot.next`.
{% endhint %}

## Async APIs

The async graph APIs support the same patterns:

```elixir
{:ok, fork_config} =
  graph
  |> Compiled.async_update_state(before_joke.config, %{topic: "chickens"})
  |> BeamWeaver.Core.Async.await()

{:ok, forked} =
  graph
  |> Compiled.async_invoke(%{}, config: fork_config)
  |> BeamWeaver.Core.Async.await()
```

Use `Compiled.async_resume/3` for interrupted checkpoints.

## Related Guides

- [Persistence](persistence.md)
- [Durable Execution](durable_execution.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Fault Tolerance](fault_tolerance.md)
- [Event Streaming](event_streaming.md)
- [Graph](graph.md)
