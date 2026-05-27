# BeamWeaver Graphs and Agents

BeamWeaver translates LangGraph behavior into Elixir modules, behaviours, and
supervised execution. It does not copy Python factories or base classes.

## Graphs

Build an immutable graph, compile it, then invoke it:

```elixir
graph =
  BeamWeaver.Graph.new()
  |> BeamWeaver.Graph.add_reducer(:messages, fn existing, update ->
    existing ++ List.wrap(update)
  end)
  |> BeamWeaver.Graph.add_node(:answer, fn state ->
    %{messages: ["hello #{state.name}"]}
  end)
  |> BeamWeaver.Graph.add_edge(BeamWeaver.Graph.start(), :answer)
  |> BeamWeaver.Graph.add_edge(:answer, BeamWeaver.Graph.end_node())
  |> BeamWeaver.Graph.compile!()

{:ok, state} = BeamWeaver.Graph.Compiled.invoke(graph, %{name: "Ada", messages: []})
```

Compiled graphs support:

- `invoke/3`, `stream_events/3`, `batch/3`, `async_invoke/3`, and `async_batch/3`
- reducer-based state merges
- guarded routes with `when:` and dynamic fan-out with `BeamWeaver.Graph.Send`
- explicit routing with `BeamWeaver.Graph.Command`
- interrupts before or after configured nodes
- checkpoint-backed `get_state/2`, `get_state_history/3`, and `update_state/4`

Event streaming returns an `Enumerable` of typed
`%BeamWeaver.Stream.Envelope{}` values. Use
`BeamWeaver.Graph.Compiled.stream_events/3` for graph progress, custom updates,
task metadata, and final lifecycle events.

## Checkpoints and Memory

Checkpointing and memory are contracts:

- `BeamWeaver.Checkpoint.Saver`
- `BeamWeaver.Memory.Store`

ETS implementations are available for local execution and tests:

```elixir
checkpointer = BeamWeaver.Checkpoint.ETS.new()
store = BeamWeaver.Memory.ETS.new()
```

Postgres support uses Ecto through adapters that implement the same behaviours:

```elixir
checkpointer = BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)
store = BeamWeaver.Memory.Ecto.new(repo: MyApp.Repo)
```

Use the SQL helper on each Ecto adapter to create the required Postgres tables
in your application schema setup.

See [Persistence](persistence.md) for checkpoint state history, updates,
pending writes, storage optimization, and adapter scope. See
[Durable Execution](durable_execution.md) for checkpoint-backed recovery and
resume design. See [Fault Tolerance](fault_tolerance.md) for node retries,
timeouts, error handlers, and failure policies.

## Agents

Agents are user modules:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  reducer :messages, fn existing, update -> existing ++ List.wrap(update) end
  node :prepare, &__MODULE__.prepare/2
  node :reply, &__MODULE__.reply/2
  edge BeamWeaver.Graph.start(), :prepare
  edge :prepare, :reply
  edge :reply, BeamWeaver.Graph.end_node()

  def prepare(state, _runtime), do: Map.put_new(state, :messages, [])

  def reply(state, runtime) do
    greeting = Map.get(runtime.context || %{}, :greeting, "hello")
    %{messages: ["#{greeting}, #{state.name}"]}
  end
end
```

Call it directly:

```elixir
{:ok, state} = MyApp.SupportAgent.invoke(%{name: "Ada"}, context: %{greeting: "hi"})
```

Or supervise it and call the server:

```elixir
{:ok, pid} = MyApp.SupportAgent.start_link([])
BeamWeaver.Agent.Server.invoke(pid, %{name: "Ada"})
```

## DAG Composition

Use explicit start/end edges for graph boundaries, `deps:` for fan-in, and
`when:` for simple constraints:

```elixir
graph =
  BeamWeaver.Graph.new(name: "ResearchPipeline")
  |> BeamWeaver.Graph.add_reducer(:reviews, fn left, right -> Map.merge(left, right) end)
  |> BeamWeaver.Graph.add_node(:plan, fn state -> %{plan: state.topic} end)
  |> BeamWeaver.Graph.add_node(:facts, FactsAgent, deps: :plan)
  |> BeamWeaver.Graph.add_node(:market, MarketAgent, deps: :plan)
  |> BeamWeaver.Graph.add_node(:facts_check, FactsVerifier,
    deps: :facts,
    output: [:reviews, :facts]
  )
  |> BeamWeaver.Graph.add_node(:market_check, MarketVerifier,
    deps: :market,
    output: [:reviews, :market]
  )
  |> BeamWeaver.Graph.add_node(:final, SummaryAgent,
    deps: [:facts_check, :market_check],
    when: %{status: :accepted}
  )
  |> BeamWeaver.Graph.add_edge(BeamWeaver.Graph.start(), :plan)
  |> BeamWeaver.Graph.add_edge(:facts_check, :facts,
    when: %{status: :needs_revision},
    max_runs: 2
  )
  |> BeamWeaver.Graph.add_edge(:market_check, :market,
    when: %{status: :needs_revision},
    max_runs: 2
  )
  |> BeamWeaver.Graph.add_edge(:final, BeamWeaver.Graph.end_node())
  |> BeamWeaver.Graph.compile!()
```

## Testing Standard

Graph and agent tests should check behavior: state transitions, persisted
history, stream payloads, interrupts, retries, tool/model errors, and adapter
contract coverage. Do not add tests that only assert copied constants,
assigned values, or supervisor children whose absence would crash the app.

## Related Guides

- [Thinking In BeamWeaver](thinking_in_beamweaver.md)
- [Workflows And Agents](workflows_and_agents.md)
- [Agents](agents.md)
- [Persistence](persistence.md)
- [Event Streaming](event_streaming.md)
