# Semantic DSL

BeamWeaver agents are normal Elixir modules. The module DSL is organized by
runtime category so a reader can see what the agent does without reverse
engineering a mixed list of options.

Use the semantic DSL for stable application code. Use `BeamWeaver.Agent.build/1`
and `BeamWeaver.Graph` builder functions when the shape is dynamic or generated
from configuration.

Public enum options in Elixir code are atom-only. Write `strategy: :auto`,
`retry_on: :transient`, and `exit_behavior: :continue`; do not write string
aliases such as `"auto"` or `"continue"`. Strings are accepted only at external
boundaries such as provider JSON, checkpoint JSON, CLI arguments, environment
variables, HTTP params, and serialized LangGraph-compatible wire shapes.

## Three Runtime Layers

BeamWeaver has one agent abstraction and three orchestration layers:

| Layer | Who controls the next step? | Use when |
| --- | --- | --- |
| Agent loop | The model chooses tools until it answers. | You want a ReAct-style model/tool loop. |
| Subagents | The parent model chooses specialist tools backed by agent modules. | You want model-visible delegation to isolated specialists. |
| Graph | Your application controls node order, fanout, joins, retries, and persistence. | You need deterministic workflow control. |

Subagents and graphs are not special agent types. They are normal composition
patterns around `use BeamWeaver.Agent`.

Middleware is separate from these orchestration layers. Middleware is lifecycle
behavior around agent, model, and tool execution. It can contribute tools when
that behavior requires tools, but graph edges, subagent declarations, schemas,
and state channels are not middleware.

## Agent Loop

```elixir
defmodule MyApp.Agents.FactExtractor do
  use BeamWeaver.Agent

  name "fact_extractor"
  description "Extract verified facts from source context."

  model "openai:gpt-5.1", temperature: 0.2, timeout: 120_000
  checkpointer MyApp.Checkpointer.new()
  store MyApp.MemoryStore.new()

  tools do
    tool MyApp.Tools.RelatedDeals
  end

  middleware do
    use BeamWeaver.Agent.Middleware.ToolCallNormalization
    use BeamWeaver.Agent.Middleware.PromptCaching
    use BeamWeaver.Agent.Middleware.StructuredOutputRetry, max_retries: 2
    use BeamWeaver.Agent.Middleware.ModelRetry, max_attempts: 6, retry_on: :transient
  end

  system_prompt "Extract only grounded facts."

  response_schema MyApp.Schemas.FactsOutput,
    name: "facts_output",
    strategy: :auto
end
```

The categories are intentionally separate:

- `model`, `checkpointer`, and `store` configure runtime infrastructure.
- `tools do` declares model-callable actions.
- `middleware do` declares lifecycle behavior around agent/model/tool execution.
- `system_prompt` declares prompt text.
- `response_schema` declares structured output.

## Tools

Use `tools do` for tools the model may call.

```elixir
tools do
  tool MyApp.Tools.RelatedDeals
  tool MyApp.Tools.Search, timeout: 30_000
  include MyApp.Tools.common_tools()
end
```

`tool Module` is preferred for stable tools. `tool expression` is useful in
small examples or generated code. `include expression` lets you append a list
from a helper without hiding the category.

Tool modules use `use BeamWeaver.Tool`:

```elixir
defmodule MyApp.Tools.SaveFact do
  use BeamWeaver.Tool

  name "save_fact"
  description "Persist one verified fact."

  injected :state, :state, type: :object
  injected :context, :context, type: :object

  schema do
    field :entity_type, :string, required: true
    field :fact_value, :string, required: true
  end

  def invoke(_tool, input, _opts) do
    state = Map.get(input, :state)
    context = Map.get(input, :context)
    MyApp.Facts.save(context.workspace_id, state.deal_id, input["entity_type"], input["fact_value"])
  end
end
```

Injected fields are available to `invoke/3` at runtime and hidden from provider
tool schemas. Use them for state, context, runtime, tool call IDs, and other
values the model should not supply.

## Middleware

Middleware is lifecycle behavior, not a bucket for every capability. Use it for
hooks and wrappers around agent/model/tool execution:

```elixir
middleware do
  use BeamWeaver.Agent.Middleware.ToolCallNormalization
  use BeamWeaver.Agent.Middleware.PromptCaching
  use BeamWeaver.Agent.Middleware.ModelRetry, max_attempts: 6, retry_on: :transient
  include MyApp.AgentMiddleware.audit_stack()
end
```

Middleware can contribute tools when that is the behavior it owns. For example,
`TodoList` is middleware because it appends planning guidance, contributes the
TODO tool, and enforces one TODO write per model turn.

Do not put subagent declarations, graph edges, state channels, or schemas in the
middleware block.

## Subagents

Use subagents when the parent model should choose whether and when to delegate.
Each specialist is its own agent module; the parent references the module and
owns only parent-specific orchestration options such as capture.

```elixir
defmodule MyApp.Agents.MeddicEvaluator do
  use BeamWeaver.Agent

  name "meddic_evaluator"
  description "Evaluate the deal using MEDDIC."

  model "openai:gpt-5.1", temperature: 0.1

  tools do
    tool MyApp.Tools.RelatedDeals
  end

  system_prompt MyApp.Prompts.meddic()
  response_schema MyApp.Schemas.MeddicOutput, name: "meddic_output"
end

defmodule MyApp.Agents.FrameworkSupervisor do
  use BeamWeaver.Agent

  name "framework_supervisor"
  model "openai:gpt-5.1"

  subagents do
    subagent MyApp.Agents.MeddicEvaluator, capture_output: :meddic_output
    subagent MyApp.Agents.BantEvaluator, capture_output: :bant_output
  end

  system_prompt "Call the framework specialists and summarize completion."
end
```

`capture_output: :key` stores the full child structured output under
`state.subagent_outputs[key]` and returns a compact acknowledgement to the
parent model. This prevents large specialist JSON from being reserialized by the
supervisor model. Non-captured subagents return their final output as the tool
message.

## Graph

Use `graph do` when the application controls execution order.

```elixir
defmodule MyApp.DealAnalysisGraph do
  use BeamWeaver.Agent

  graph do
    state do
      channel :summary, merge: :last
      channel :framework, merge: :map
      channel :action, merge: :last
    end

    node :summary, MyApp.Agents.SummaryAgent, output: :summary
    node :meddic, MyApp.Agents.MeddicEvaluator, deps: [:summary], output: [:framework, :meddic]
    node :bant, MyApp.Agents.BantEvaluator, deps: [:summary], output: [:framework, :bant]
    node :action, MyApp.Agents.ActionAgent, deps: [:meddic, :bant], output: :action

    edge start(), :summary
    edge :summary, :meddic
    edge :summary, :bant
    join [:meddic, :bant], :action
    edge :action, finish()
  end
end
```

Graph declarations support:

- `state do channel :key, merge: :last | :map | :list | fun end`
- `node :name, callable, opts`
- `edge start(), :node`
- `edge :node, finish()`
- `edge :node, :other, when: pattern, max_runs: n`
- `join [:a, :b], :c`
- `reducer :key, fun`

Use `BeamWeaver.Graph` builder functions when graph shape is dynamic, loaded
from a database, or generated from user configuration.

## Subagents Or Graphs

Use subagents when the model should choose whether to delegate:

```elixir
subagents do
  subagent MyApp.Agents.MeddicEvaluator, capture_output: :meddic_output
  subagent MyApp.Agents.BantEvaluator, capture_output: :bant_output
end
```

Use a graph when the application controls fanout, joins, aggregation, retries,
or persistence:

```elixir
graph do
  state do
    channel :framework, merge: :map
  end

  node :summary, MyApp.Agents.SummaryAgent, output: :summary
  node :meddic, MyApp.Agents.MeddicEvaluator, deps: [:summary], output: [:framework, :meddic]
  node :bant, MyApp.Agents.BantEvaluator, deps: [:summary], output: [:framework, :bant]
  node :aggregate, MyApp.Agents.FrameworkAggregator, deps: [:meddic, :bant], output: :framework

  edge start(), :summary
  edge :summary, :meddic
  edge :summary, :bant
  join [:meddic, :bant], :aggregate
  edge :aggregate, finish()
end
```

The same specialist modules can be used in both patterns. The difference is
who decides the next step: the parent model for subagents, your application for
graphs.

## Schemas

Use `BeamWeaver.Schema` for structured output and reusable nested objects.

```elixir
defmodule MyApp.Schemas.FactsOutput do
  use BeamWeaver.Schema

  title "facts_output"
  description "Extracted entity facts and client requests."
  strict true

  field :entity_facts, {:array, MyApp.Schemas.EntityFact}, required: true
  field :client_requests, {:array, MyApp.Schemas.ClientRequest}, required: true
end
```

The module exposes `json_schema/0`, `schema/0`, and
`__beam_weaver_schema__/0`. In stable agent modules, prefer schema modules with
`response_schema/2`. Raw JSON Schema maps belong at wire boundaries,
runtime-generated dynamic tools, or provider payloads.

```elixir
response_schema MyApp.Schemas.FactsOutput,
  name: "facts_output",
  strategy: :auto
```

Strategies:

- `:auto` lets BeamWeaver choose the safest provider-compatible strategy.
- `:provider` requests provider-native structured output.
- `:tool` uses a structured-output pseudo tool.

Strategy values are atoms. String strategy aliases are rejected in public Elixir
configuration so mistakes fail early.

Use `:auto` unless you are testing a provider capability directly or need to
force a specific trace shape.

## Deep Agents Are Composition

A BeamWeaver deep agent is a normal agent with more capabilities composed:

```elixir
defmodule MyApp.Agents.ResearchAgent do
  use BeamWeaver.Agent

  name "research_agent"
  model "anthropic:claude-sonnet-4-6", timeout: 120_000
  filesystem BeamWeaver.Filesystem.State.new()
  compact_conversation true
  overflow_recovery true
  memory ["/project-memory.md"]

  tools do
    tool MyApp.Tools.Search
  end

  subagents do
    subagent MyApp.Agents.SourceReviewer, capture_output: :source_review
  end

  middleware do
    use BeamWeaver.Agent.Middleware.TodoList, tool_name: "write_todos"
    use BeamWeaver.Agent.Middleware.ToolCallNormalization
    use BeamWeaver.Agent.Middleware.ModelRetry, max_attempts: 6, retry_on: :transient
  end

  system_prompt "Research deeply, keep notes when useful, and return sourced findings."
end
```

There is no `DeepAgent` module, harness flag, or opt-out API. Add the tools,
middleware, memory, filesystem, subagents, checkpointing, and tracing behavior
you want; omit the behavior you do not want.

## Which DSL Should I Use?

| Need | Use |
| --- | --- |
| Stable model/tool loop | `use BeamWeaver.Agent` with `tools do` |
| Runtime-configured agent | `BeamWeaver.Agent.build/1` |
| Model-chosen specialist delegation | `subagents do` |
| App-controlled workflow order | `graph do` |
| Dynamic/config-generated graph | `BeamWeaver.Graph` builder functions |
| Structured LLM response | `BeamWeaver.Schema` plus `response_schema/2` |
| Runtime-only tool values | `injected/3` in `use BeamWeaver.Tool` |

## Tracing Shape

Native tracing follows the execution shape:

- Agent runs appear as graph-backed agent spans.
- Middleware hooks and wrappers appear as short nested spans.
- Model spans include bound tools and model output tool calls.
- Tool spans link to the model tool call ID and contain the tool result.
- Captured subagents appear as bounded specialist tool spans, with capture
  metadata and compact parent acknowledgements.
- Structured output appears as a sequence-like generation span, with provider
  metadata and parsed output on the structured span.

Use trace metadata such as `subagent_name`, `capture_key`, `execution_mode`,
structured-output strategy, custom fields, and tool call IDs when building
assertions or comparing provider behavior.
