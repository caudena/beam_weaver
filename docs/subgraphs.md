# Subgraphs

A subgraph is a compiled graph used as a node in another graph. Use subgraphs
when you want to reuse a workflow, split ownership across teams, compose
specialist agents, or keep part of a graph's state boundary isolated from the
parent.

In BeamWeaver, subgraphs are ordinary `BeamWeaver.Graph.Compiled` values. You
can pass a compiled graph directly to `BeamWeaver.Graph.add_node/4`, or use an
agent module or compiled agent graph as the node.

{% hint style="info" %}
**BeamWeaver Shape**

LangGraph's Python docs use `StateGraph`, `TypedDict`, `START`, `END`,
`graph.stream(..., subgraphs=True, version="v2")`, and
`get_state(config, subgraphs=True)`. BeamWeaver uses `BeamWeaver.Graph`,
compiled graph nodes, optional `input:` and `output:` projections,
`BeamWeaver.Graph.Compiled.stream_events/3`, and checkpoint namespace configs
from state history.
{% endhint %}

## Setup

BeamWeaver is installed as an Elixir dependency, not with `pip` or `uv`:

```elixir
def deps do
  [
    {:beam_weaver, "~> 0.1.6"}
  ]
end
```

See [Getting Started](getting_started.md) for the full project setup.

## Define Subgraph Communication

Choose the communication pattern based on whether the parent and child share
state keys.

| Pattern | When To Use | BeamWeaver Shape |
| --- | --- | --- |
| [Different state shapes](#different-state-shapes) | Parent and child have different keys or you need to transform state. | Add the compiled child as a node with `input:` and `output:` projections, or manually call the child from a wrapper node. |
| [Shared state shapes](#shared-state-shapes) | Parent and child read and write the same state channels. | Pass the compiled child directly to `add_node/4`. |

Prefer compiled subgraph nodes with projections when you need persistence,
interrupts, tracing, or subgraph stream events. Manual invocation inside a
normal node works, but then your node owns config, resume, error, and stream
propagation.

## Different State Shapes

When the parent and subgraph use different state keys, adapt the boundary with
`input:` and `output:` projections:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

child =
  Graph.new(name: "ChildGraph")
  |> Graph.add_node(:subgraph_node_1, fn state ->
    %{bar: "hi! " <> state.bar}
  end)
  |> Graph.add_edge(Graph.start(), :subgraph_node_1)
  |> Graph.add_edge(:subgraph_node_1, Graph.end_node())
  |> Graph.compile!()

parent =
  Graph.new(name: "ParentGraph")
  |> Graph.add_node(:call_child, child,
    input: fn parent_state -> %{bar: parent_state.foo} end,
    output: fn child_state -> %{foo: child_state.bar} end
  )
  |> Graph.add_edge(Graph.start(), :call_child)
  |> Graph.add_edge(:call_child, Graph.end_node())
  |> Graph.compile!()

{:ok, state} =
  Compiled.invoke(parent, %{foo: "Bob"})

state.foo
#=> "hi! Bob"
```

The child remains a real subgraph node, so it can inherit checkpointers, stores,
context, recursion limits, interrupts, and stream collection from the parent.

If you intentionally want a plain wrapper node, call the child explicitly:

```elixir
call_child = fn state ->
  {:ok, child_state} = Compiled.invoke(child, %{bar: state.foo})
  %{foo: child_state.bar}
end
```

That shape is useful for simple synchronous transformations. It is less useful
for durable subgraph workflows because the parent runtime cannot automatically
route checkpoint namespace, resume values, or child events through an arbitrary
manual call.

## Nested Subgraphs

Subgraphs can contain other subgraphs:

```elixir
inner =
  Graph.new(name: "InnerGraph")
  |> Graph.add_node(:inner_node, fn state -> %{value: state.value <> "!"} end)
  |> Graph.add_edge(Graph.start(), :inner_node)
  |> Graph.add_edge(:inner_node, Graph.end_node())
  |> Graph.compile!()

middle =
  Graph.new(name: "MiddleGraph")
  |> Graph.add_node(:inner, inner)
  |> Graph.add_edge(Graph.start(), :inner)
  |> Graph.add_edge(:inner, Graph.end_node())
  |> Graph.compile!()

outer =
  Graph.new(name: "OuterGraph")
  |> Graph.add_node(:middle, middle)
  |> Graph.add_edge(Graph.start(), :middle)
  |> Graph.add_edge(:middle, Graph.end_node())
  |> Graph.compile!()
```

Stream namespaces and checkpoint namespaces become path-like as nesting gets
deeper, for example `["middle", "inner"]` in stream events or `"middle/inner"`
in checkpoint configs.

## Shared State Shapes

When parent and child share state keys, pass the child graph directly:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

child =
  Graph.new(name: "SharedChild")
  |> Graph.add_node(:subgraph_node_1, fn state ->
    %{foo: "hi! " <> state.foo}
  end)
  |> Graph.add_edge(Graph.start(), :subgraph_node_1)
  |> Graph.add_edge(:subgraph_node_1, Graph.end_node())
  |> Graph.compile!()

parent =
  Graph.new(name: "SharedParent")
  |> Graph.add_node(:node_1, fn state -> %{foo: state.foo <> " from parent"} end)
  |> Graph.add_node(:node_2, child)
  |> Graph.add_edge(:node_1, :node_2)
  |> Graph.add_edge(Graph.start(), :node_1)
  |> Graph.add_edge(:node_2, Graph.end_node())
  |> Graph.compile!()

{:ok, state} =
  Compiled.invoke(parent, %{foo: "Bob"})

state.foo
#=> "hi! Bob from parent"
```

If the child has keys that should not flow back to the parent, use an `output:`
projection or a child `output_schema` to keep the public boundary explicit.

## Agents As Subgraphs

Agents compile to graphs, so an agent can be nested in a larger workflow:

```elixir
{:ok, expert_graph} =
  BeamWeaver.Agent.compiled_graph(MyApp.FruitExpert)

workflow =
  BeamWeaver.Graph.new(name: "SupportWorkflow")
  |> BeamWeaver.Graph.add_node(:fruit_expert, expert_graph,
    input: fn state ->
      %{messages: [BeamWeaver.Core.Message.user(state.question)]}
    end,
    output: fn expert_state ->
      %{answer: expert_state.messages |> List.last() |> BeamWeaver.Core.Message.text()}
    end
  )
  |> BeamWeaver.Graph.add_edge(BeamWeaver.Graph.start(), :fruit_expert)
  |> BeamWeaver.Graph.add_edge(:fruit_expert, BeamWeaver.Graph.end_node())
  |> BeamWeaver.Graph.compile!()
```

The agent's tools, middleware, human review, summarization, retries, and model
selection stay inside the compiled agent subgraph. If a per-thread subagent is
exposed as a tool, use `BeamWeaver.Agent.Middleware.ToolCallLimit` or provider
model options to prevent parallel calls to the same persistent subgraph.

## Subgraph Persistence

Subgraph persistence is controlled by the child's `checkpointer:` compile
option. The parent must have a checkpointer for inherited or shared subgraph
checkpointing to persist.

| Mode | Compile Option | Behavior |
| --- | --- | --- |
| Per-invocation default | omitted, `nil`, or `:inherit` | The child inherits the parent adapter and uses a task-scoped namespace such as `"child:<task_id>"`. Each call starts fresh, while interrupts and durable execution work within that call. |
| Per-thread | `true` or `:shared` | The child inherits the parent adapter with a stable namespace such as `"child"`. State accumulates across calls on the same thread. |
| Stateless | `false` or `:disabled` | The child does not checkpoint internally. It behaves like a plain function call with no durable child resume or state inspection. |
| Local adapter | a `BeamWeaver.Checkpoint.Saver` adapter | The child uses its own checkpointer adapter instead of the parent adapter. |

Examples:

```elixir
# Per-invocation: inherits parent checkpointer, task-scoped namespace.
child = Graph.compile!(child_builder)

# Per-thread: stable namespace on the same parent thread.
child = Graph.compile!(child_builder, checkpointer: true)

# Stateless: no child checkpointing.
child = Graph.compile!(child_builder, checkpointer: false)

# Local adapter: child uses a dedicated checkpointer.
child =
  Graph.compile!(child_builder,
    checkpointer: BeamWeaver.Checkpoint.ETS.new()
  )
```

{% hint style="warning" %}
**Parallel Per-Thread Calls**

Do not call the same per-thread subgraph multiple times in parallel on the same
thread. Those calls target the same stable checkpoint namespace and can conflict.
Use the default per-invocation mode for independent fan-out calls, or give each
persistent subgraph a distinct node name and namespace.
{% endhint %}

## Interrupts In Subgraphs

Subgraph interrupts bubble to the parent run. Resume through the parent graph
with the same config:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

child =
  Graph.new(name: "ApprovalChild")
  |> Graph.add_node(:approval, fn _state ->
    answer = Graph.interrupt("continue?")
    %{approved: answer}
  end)
  |> Graph.add_edge(Graph.start(), :approval)
  |> Graph.add_edge(:approval, Graph.end_node())
  |> Graph.compile!()

checkpointer = BeamWeaver.Checkpoint.ETS.new()
config = %{"configurable" => %{"thread_id" => "subgraph-hitl"}}

parent =
  Graph.new(name: "ApprovalParent")
  |> Graph.add_node(:child, child)
  |> Graph.add_edge(Graph.start(), :child)
  |> Graph.add_edge(:child, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

{:interrupted, interrupt} =
  Compiled.invoke(parent, %{}, config: config)

{:ok, state} =
  Compiled.resume(parent, %{interrupt.id => true}, config: config)
```

Use [Human-In-The-Loop](human_in_the_loop.md) for interrupt rules and
[Durable Execution](durable_execution.md) for replay-safe side effects.

## View Subgraph State

BeamWeaver does not expose Python's `get_state(config, subgraphs=True)` shape.
Subgraph checkpoint configs are visible through state history. Filter by
`checkpoint_ns`:

```elixir
history =
  Compiled.get_state_history(parent, config)

child_snapshot =
  Enum.find(history, fn snapshot ->
    get_in(snapshot.config, ["configurable", "checkpoint_ns"]) == "child"
  end)

{:ok, child_state} =
  Compiled.get_state(parent, child_snapshot.config)
```

For per-invocation subgraphs, the namespace includes the task ID, such as
`"child:01J..."`. For shared subgraphs, the namespace is stable, such as
`"child"`. For nested shared subgraphs, it is path-like, such as
`"middle/inner"`.

State is only available when checkpointing is enabled. Stateless subgraphs have
no saved child state to inspect.

## Stream Subgraph Outputs

`BeamWeaver.Graph.Compiled.stream_events/3` returns typed
`%BeamWeaver.Stream.Envelope{}` values. Subgraph events are included in the same
event stream with a non-empty namespace:

```elixir
{:ok, events} =
  Compiled.stream_events(parent, %{foo: "foo"})

for %{namespace: namespace, event: event} <- events, namespace != [] do
  IO.inspect({namespace, event})
end
```

Use `BeamWeaver.Stream.Subgraphs.from_events/2` for a subgraph-focused
projection:

```elixir
runs =
  events
  |> BeamWeaver.Stream.Subgraphs.from_events()
  |> BeamWeaver.Stream.Subgraphs.flatten()

Enum.map(runs, & &1.path)
```

This replaces the Python `subgraphs=True` stream option and `StreamPart` chunks
with native Elixir stream envelopes and projection structs.

{% hint style="info" %}
**No `subgraphs: true` Stream Flag**

BeamWeaver subgraph events are already present in typed graph event streams
when the subgraph runs as a graph node. Use envelope namespaces or
`BeamWeaver.Stream.Subgraphs` instead of enabling a separate stream flag.
{% endhint %}

## Related Guides

- [Graph](graph.md)
- [Persistence](persistence.md)
- [Memory](memory.md)
- [Time Travel](time_travel.md)
- [Durable Execution](durable_execution.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Event Streaming](event_streaming.md)
- [Agents](agents.md)
- [Subagents](subagents.md)
- [Middleware](middleware.md)
