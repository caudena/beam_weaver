# DSL Migration Guide

This guide moves older BeamWeaver module declarations to the semantic DSL. The
runtime behavior should stay the same; the source code becomes clearer about
which category each declaration belongs to.

The dynamic APIs remain available:

- `BeamWeaver.Agent.build/1` for runtime-generated agents.
- `BeamWeaver.Graph` builder functions for runtime-generated graphs.
- `BeamWeaver.Tool.from_function!/1` for runtime-generated tools.

Prefer the semantic module DSL for stable application modules.

## Compatibility-Only APIs

These APIs may still appear in old code, tests, or dynamic builders, but they
are not the preferred public module DSL:

- `tools([...])`
- `middleware([...])`
- `subagents([...])`
- raw JSON Schema maps embedded in agent modules
- `response_format/1` in stable agent modules
- compatibility capability bundles such as `base_middleware: [:deepagents]`
- old Deep Agents "harness" vocabulary used by Python-porting layers

Move stable modules to `tools do`, `middleware do`, `subagents do`,
`graph do`, `BeamWeaver.Schema`, and `response_schema/2`. Keep raw schema maps
only for provider payloads, tool schema wire data, dynamic construction, or
compatibility migrations.

Public enum options in Elixir code are atom-only. Convert string aliases:

| Before | After |
| --- | --- |
| `"auto"` | `:auto` |
| `"tool"` | `:tool` |
| `"provider"` | `:provider` |
| `"continue"` | `:continue` |
| `"error"` | `:error` |
| `"end"` | `:end` |
| `"heartbeat"` | `:heartbeat` |
| `"model"` | `:model` |
| `"approximate"` | `:approximate` |

String values remain valid only at external boundaries such as CLI args, env
vars, HTTP params, provider JSON, checkpoint JSON, and serialized wire formats.

## Tools

Before:

```elixir
tools([
  MyApp.Tools.Search,
  MyApp.Tools.RelatedDeals
])
```

After:

```elixir
tools do
  tool MyApp.Tools.Search
  tool MyApp.Tools.RelatedDeals
end
```

With options:

```elixir
tools do
  tool MyApp.Tools.Search, timeout: 30_000
  include MyApp.Tools.common_tools()
end
```

`include` is the explicit escape hatch for helper-returned lists.

## Middleware

Before:

```elixir
middleware([
  BeamWeaver.Agent.Middleware.ToolCallNormalization,
  {BeamWeaver.Agent.Middleware.ModelRetry, max_attempts: 6, retry_on: :transient}
])
```

After:

```elixir
middleware do
  use BeamWeaver.Agent.Middleware.ToolCallNormalization
  use BeamWeaver.Agent.Middleware.ModelRetry, max_attempts: 6, retry_on: :transient
end
```

Use `include` only when middleware is genuinely configured elsewhere:

```elixir
middleware do
  include MyApp.AgentRuntime.retry_stack()
end
```

Middleware should be lifecycle behavior around agent/model/tool execution.
Tools, subagents, graph nodes, state channels, and schemas belong in their own
DSL sections.

## Subagents

Before:

```elixir
alias BeamWeaver.Agent.Subagent

subagents([
  Subagent.Spec.new(
    name: "meddic_evaluator",
    description: "Evaluate the deal using MEDDIC.",
    system_prompt: MyApp.Prompts.meddic(),
    tools: [MyApp.Tools.RelatedDeals],
    response_format: MyApp.Runtime.response_format(MyApp.Schemas.MeddicOutput.json_schema()),
    capture_output: :meddic_output
  )
])
```

After:

```elixir
defmodule MyApp.Agents.MeddicEvaluator do
  use BeamWeaver.Agent

  name "meddic_evaluator"
  description "Evaluate the deal using MEDDIC."
  model "openai:gpt-5.1"

  tools do
    tool MyApp.Tools.RelatedDeals
  end

  system_prompt MyApp.Prompts.meddic()
  response_schema MyApp.Schemas.MeddicOutput, name: "meddic_output"
end

defmodule MyApp.Agents.FrameworkSupervisor do
  use BeamWeaver.Agent

  subagents do
    subagent MyApp.Agents.MeddicEvaluator, capture_output: :meddic_output
  end
end
```

Child modules own child behavior: name, description, prompt, tools,
middleware, model, schema. Parent modules own parent-only orchestration:
capture, async/sync use, and workflow order.

## Structured Output

Before:

```elixir
response_format(
  BeamWeaver.Agent.StructuredOutput.tool(%{
    "title" => "facts_output",
    "type" => "object",
    "required" => ["facts"],
    "properties" => %{"facts" => %{"type" => "array", "items" => %{"type" => "string"}}}
  })
)
```

After:

```elixir
defmodule MyApp.Schemas.FactsOutput do
  use BeamWeaver.Schema

  title "facts_output"
  strict true

  field :facts, {:array, :string}, required: true
end

response_schema MyApp.Schemas.FactsOutput,
  name: "facts_output",
  strategy: :auto
```

Use `response_schema/2` for agent modules. Keep `response_format/1` only for
low-level tests or dynamic code that already has a fully built strategy.

## Tool Injected Values

Before:

```elixir
Tool.from_function!(
  name: "save_fact",
  input_schema: %{"type" => "object", "properties" => %{"fact" => %{"type" => "string"}}},
  injected: %{state: :state, context: :context},
  handler: fn input, _opts -> save(input) end
)
```

After:

```elixir
defmodule MyApp.Tools.SaveFact do
  use BeamWeaver.Tool

  name "save_fact"
  description "Persist a verified fact."

  injected :state, :state, type: :object
  injected :context, :context, type: :object

  schema do
    field :fact, :string, required: true
  end
end
```

Injected fields are runtime-visible and provider-hidden.

## Graphs

Before:

```elixir
graph =
  BeamWeaver.Graph.new(name: "DealWorkflow")
  |> BeamWeaver.Graph.add_reducer(:framework, fn left, right -> Map.merge(left, right) end)
  |> BeamWeaver.Graph.add_node(:summary, MyApp.Agents.SummaryAgent, output: :summary)
  |> BeamWeaver.Graph.add_node(:meddic, MyApp.Agents.MeddicEvaluator, deps: :summary, output: [:framework, :meddic])
  |> BeamWeaver.Graph.add_node(:bant, MyApp.Agents.BantEvaluator, deps: :summary, output: [:framework, :bant])
  |> BeamWeaver.Graph.add_node(:action, MyApp.Agents.ActionAgent, deps: [:meddic, :bant], output: :action)
  |> BeamWeaver.Graph.add_edge(BeamWeaver.Graph.start(), :summary)
  |> BeamWeaver.Graph.add_edge(:summary, :meddic)
  |> BeamWeaver.Graph.add_edge(:summary, :bant)
  |> BeamWeaver.Graph.add_join([:meddic, :bant], :action)
  |> BeamWeaver.Graph.add_edge(:action, BeamWeaver.Graph.end_node())
```

After:

```elixir
defmodule MyApp.DealWorkflow do
  use BeamWeaver.Agent

  graph do
    state do
      channel :framework, merge: :map
    end

    node :summary, MyApp.Agents.SummaryAgent, output: :summary
    node :meddic, MyApp.Agents.MeddicEvaluator, deps: :summary, output: [:framework, :meddic]
    node :bant, MyApp.Agents.BantEvaluator, deps: :summary, output: [:framework, :bant]
    node :action, MyApp.Agents.ActionAgent, deps: [:meddic, :bant], output: :action

    edge start(), :summary
    edge :summary, :meddic
    edge :summary, :bant
    join [:meddic, :bant], :action
    edge :action, finish()
  end
end
```

Keep builder functions when the graph shape is not known at compile time.

## Deep Agent Composition

Before:

```elixir
Agent.build(
  name: "research_agent",
  model: "anthropic:claude-sonnet-4-6",
  tools: [MyApp.Tools.Search],
  filesystem: BeamWeaver.Filesystem.State.new(),
  subagents: [researcher_spec],
  compact_conversation: true,
  overflow_recovery: true,
  middleware: [{BeamWeaver.Agent.Middleware.TodoList, tool_name: "write_todos"}]
)
```

After, for a stable module:

```elixir
defmodule MyApp.Agents.ResearchAgent do
  use BeamWeaver.Agent

  name "research_agent"
  model "anthropic:claude-sonnet-4-6"
  filesystem BeamWeaver.Filesystem.State.new()
  compact_conversation true
  overflow_recovery true

  tools do
    tool MyApp.Tools.Search
  end

  subagents do
    subagent MyApp.Agents.Researcher, capture_output: :research_output
  end

  middleware do
    use BeamWeaver.Agent.Middleware.TodoList, tool_name: "write_todos"
    use BeamWeaver.Agent.Middleware.ModelRetry, max_attempts: 6, retry_on: :transient
  end
end
```

There is still no separate deep-agent constructor. The module is deep because it
composes the capabilities it needs.
