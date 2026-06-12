# Subagents

Subagents let a BeamWeaver agent delegate isolated work through the `task`
tool. A subagent receives a fresh message context and runs as a normal
BeamWeaver agent. It returns one final result to the parent; for structured
specialists it can also capture the full output in graph state and return only
a compact acknowledgement. This is useful when a task would otherwise fill the
parent context with intermediate searches, file reads, tool outputs, or large
specialist payloads.

Use subagents for multi-step work, specialized tool sets, or tasks that should
use a different model or prompt. Do not use them for simple one-step lookups, or
when the parent must inspect every intermediate message as part of the active
conversation.

{% hint style="info" %}
**Subagents vs Graphs**

Task subagents are launched by the model as tool calls. Use subagents when the
parent model should choose the specialist. Use `graph do` when the application
must control deterministic order, fanout, joins, retries, aggregation, or
persistence. Use [Subgraphs](subgraphs.md) when you need a nested graph that is
visible in the compiled topology, state history, and graph-level inspection
APIs.
{% endhint %}

## Composition Model

BeamWeaver has one agent abstraction. There is no separate `DeepAgent` type and
no `create_deep_agent` constructor. An agent becomes "deep" only by composing
the capabilities it needs:

- TODO planning through `BeamWeaver.Agent.Middleware.TodoList` or
  `BeamWeaver.Tools.Todo`.
- Virtual files through `filesystem`, `BeamWeaver.Agent.Middleware.Filesystem`,
  or `BeamWeaver.Tools.Filesystem`.
- Delegation through `subagents` or `BeamWeaver.Agent.Middleware.Subagents`.
- Memory, compaction, overflow recovery, checkpointing, skills, and HITL
  through their normal agent fields or middleware entries.

Capabilities are positive declarations. If you do not include TODO middleware,
there is no TODO behavior. If you do not include filesystem middleware or a
filesystem agent field, there are no filesystem tools. If you do not configure
subagents, there is no `task` tool.

## Enable The Task Tool

Declare synchronous subagents in a `subagents do` block. BeamWeaver adds a
model-visible `task` tool only when at least one synchronous subagent is
configured.

```elixir
defmodule MyApp.Agents.Researcher do
  use BeamWeaver.Agent

  name "researcher"
  description "Conduct multi-step web research and return concise sourced notes."

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  tools do
    tool MyApp.Tools.WebSearch
  end

  system_prompt """
  You are a focused research assistant.
  Use web_search when useful.
  Return only essential findings and source URLs.
  Keep the response under 500 words.
  """
end

defmodule MyApp.Agents.MainAgent do
  use BeamWeaver.Agent

  name "main_agent"
  description "Coordinate answers and delegate deep research."

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  tools do
    tool MyApp.Tools.WebSearch
  end

  subagents do
    subagent MyApp.Agents.Researcher
  end

  system_prompt """
  Coordinate the answer. Delegate deep research to the researcher when a
  question needs multiple searches or source synthesis.
  """
end

{:ok, state} =
  MyApp.Agents.MainAgent.invoke(%{
    messages: [
      BeamWeaver.Core.Message.user("Research recent changes in vector database pricing.")
    ]
  })
```

The `task` tool accepts:

| Argument | Meaning |
| --- | --- |
| `description` | The full assignment for the subagent. Include all context the child needs. |
| `subagent_name` or `subagent_type` | The configured subagent name, such as `"researcher"`. |

The child starts with `description` as its user message. The parent receives one
tool result containing either the child's structured response encoded as JSON,
or the last assistant message from the child.

Parent messages are not inherited by default. Set `inherit_messages: true` only
when the child really needs the parent transcript; BeamWeaver filters parent
tool protocol messages before passing inherited messages to the child.

## Parent And Child Ownership

The parent owns delegation policy. The child owns its prompt, model, tools,
middleware, and structured output:

```elixir
defmodule MyApp.Agents.NarrativeCompressor do
  use BeamWeaver.Agent

  name "narrative_compressor"
  description "Build the authoritative relationship narrative and timeline."

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  tools do
    tool MyApp.Tools.RelatedDeals
  end

  middleware do
    use BeamWeaver.Agent.Middleware.ToolCallNormalization
    use BeamWeaver.Agent.Middleware.StructuredOutputRetry, max_retries: 2
  end

  system_prompt "Return only the requested structured narrative output."
  response_schema MyApp.Schemas.NarrativeOutput, name: "narrative_output"
end

defmodule MyApp.Agents.SummarySupervisor do
  use BeamWeaver.Agent

  name "summary_supervisor"
  description "Coordinate deal summary specialists."

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  subagents do
    subagent MyApp.Agents.NarrativeCompressor, capture_output: :narrative_output
  end

  system_prompt "Delegate narrative work to the narrative_compressor specialist."
end
```

## Subagent Specs

Module-based subagents are the preferred public DSL. Use
`BeamWeaver.Agent.Subagent.Spec.new/1` only when the subagent list is generated
at runtime from configuration. It accepts keyword lists and atom-keyed maps.

| Field | Type | Behavior |
| --- | --- | --- |
| `:name` | string | Required. Unique subagent name selected by the parent through `task`. |
| `:description` | string | Required. Model-facing description used to choose the right subagent. |
| `:system_prompt` | string | Recommended. Prepended to BeamWeaver's focused-subagent prompt. BeamWeaver accepts `nil`, but useful subagents should define their role and output shape. |
| `:tools` | list | Optional. Inherits parent tools when `nil`; use `[]` to give the subagent no parent tools. Any list replaces the inherited list. |
| `:model` | model | Optional. Inherits the parent model when omitted. |
| `:middleware` | list | Optional. Subagent-specific middleware. Parent middleware is not inherited. |
| `:interrupt_on` | map or boolean | Optional. Inherits parent HITL configuration when omitted. A child map overrides the parent policy; current generated subagents treat `false` like inheritance, so use a narrower map, remove tools, or use a compiled subagent to opt out. Requires checkpointing to resume. |
| `:skills` | list | Optional. Inherits parent skills when `nil`; use `[]` to opt out, or provide a list to replace the inherited skills. |
| `:permissions` | list | Optional. Inherits parent filesystem permissions when omitted; a list replaces the inherited rules. |
| `:response_format` | structured output config | Optional. Dynamic equivalent of `response_schema/2` on a child module. |
| `:capture_output` | atom or keyword | Optional. Stores the child output in `state.subagent_outputs[key]` and returns a compact acknowledgement to the parent. Public Elixir config uses atom keys. |
| `:execution_mode` | atom | Optional. `:agent_loop` by default; use `:structured_once` or `:research_then_generate` for specialist patterns. |

Dynamic generated child agents use the same capability rules as module agents:
tools and middleware are present only when you declare them. They do not
automatically receive TODO, filesystem, skills, summarization, or compaction
middleware.

```elixir
alias BeamWeaver.Agent.Subagent

Subagent.Spec.new(
  name: "file_researcher",
  description: "Researches files and returns concise findings.",
  system_prompt: "Use files only when needed and keep the answer short.",
  tools: [MyApp.Tools.SearchDocs],
  middleware: [
    {BeamWeaver.Agent.Middleware.TodoList, tool_name: "write_todos"},
    BeamWeaver.Agent.Middleware.Filesystem
  ]
)
```

For path rule examples and the distinction between inherited, replaced, and
unrestricted subagent permissions, see [Filesystem Permissions](permissions.md).

## Compiled Subagents

For complex workflows, provide a prebuilt BeamWeaver agent with
`BeamWeaver.Agent.Subagent.Compiled`. The `:agent` must be a module-defined
agent or a `%BeamWeaver.Agent.Built{}` returned by `BeamWeaver.Agent.build/1`.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Agent.Subagent

{:ok, analyzer} =
  Agent.build(
    name: "data-analyzer",
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
    tools: [MyApp.Tools.QueryWarehouse],
    system_prompt: "Analyze tabular data and return concise findings."
  )

{:ok, supervisor} =
  Agent.build(
    name: "analysis-supervisor",
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
    subagents: [
      %Subagent.Compiled{
        name: "data-analyzer",
        description: "Analyzes warehouse data and reports trends.",
        agent: analyzer
      }
    ]
  )
```

If you have a compiled graph rather than an agent, use
[Subgraphs](subgraphs.md) or wrap the behavior in a BeamWeaver agent module.
`Compiled` is intentionally an agent delegation API, not an arbitrary graph
runnable slot.

## General-Purpose Subagents

Official Python Deep Agents automatically adds a synchronous `general-purpose`
subagent by default. BeamWeaver's normal `BeamWeaver.Agent.build/1` and
`use BeamWeaver.Agent` flow does not auto-inject that subagent. If you want a
general-purpose delegate, declare it explicitly:

```elixir
defmodule MyApp.Agents.GeneralPurpose do
  use BeamWeaver.Agent

  name "general-purpose"
  description "Handles isolated multi-step work when no specialist fits."

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  system_prompt """
  You are a general-purpose delegated assistant.
  Complete the task independently and return only the final answer.
  """
end

defmodule MyApp.Agents.Supervisor do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  subagents do
    subagent MyApp.Agents.GeneralPurpose
  end
end
```

To run without the `task` tool, omit `subagents`, pass `subagents: []`, or pass
`subagents: false`. Async subagents use a separate tool surface and do not
create the synchronous `task` tool by themselves.

## Structured Output

Subagents can use the same structured-output strategies as top-level agents.
When a child agent writes `:structured_response`, the `task` tool returns that
response as JSON to the parent.

```elixir
defmodule MyApp.Schemas.ResearchFindings do
  use BeamWeaver.Schema

  title "research_findings"
  description "Concise sourced research findings."
  strict true

  field :summary, :string, required: true
  field :confidence, :number, required: true
  field :sources, {:array, :string}, required: true
end

defmodule MyApp.Agents.Researcher do
  use BeamWeaver.Agent

  name "researcher"
  description "Researches a topic and returns structured findings."

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  tools do
    tool MyApp.Tools.WebSearch
  end

  system_prompt "Return a concise structured answer with source URLs."
  response_schema MyApp.Schemas.ResearchFindings, name: "research_findings", strategy: :tool
end
```

Without `response_format`, the parent receives the last assistant message text
from the child.

## Captured Specialist Outputs

Use `capture_output` when the parent should coordinate specialists without
re-emitting their full structured payloads through the supervisor model. The
child output is written to `state.subagent_outputs[key]`, while the `task` tool
message contains a short JSON acknowledgement.

```elixir
defmodule MyApp.Schemas.NarrativeOutput do
  use BeamWeaver.Schema

  title "narrative_output"
  strict true

  field :summary, :string, required: true
  field :timeline, {:array, :object}, required: true
end

defmodule MyApp.Agents.NarrativeCompressor do
  use BeamWeaver.Agent

  name "narrative_compressor"
  description "Builds the authoritative relationship narrative and timeline."

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  system_prompt "Return only the requested structured narrative output."
  response_schema MyApp.Schemas.NarrativeOutput,
    name: "narrative_output",
    strategy: :provider
end

defmodule MyApp.Agents.SummarySupervisor do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  subagents do
    subagent MyApp.Agents.NarrativeCompressor, capture_output: :narrative_output
  end
end
```

After the parent calls `task`, the graph state includes:

```elixir
state.subagent_outputs["narrative_output"]
# %{"summary" => "...", "timeline" => [...]}
```

The parent model sees only an acknowledgement similar to:

```json
{
  "status": "captured",
  "subagent_name": "narrative_compressor",
  "capture_key": "narrative_output",
  "cache_hit": false,
  "input_hash": "..."
}
```

Captured values are normalized to JSON-safe maps, lists, strings, numbers,
booleans, or `nil`, and are persisted through checkpoints. Captured state is
not inherited by child subagents, so specialist payloads do not recursively
inflate child context.

Captured subagents are visible in native traces as child agent runs and compact
parent tool messages. The parent-visible tool output is the same compact
acknowledgement the parent model saw; the captured `state.subagent_outputs`
payload stays internal and is not uploaded as tool message content.

Repeated captured calls are deduped by `{subagent_name, input_hash}` by
default. BeamWeaver stores cache entries in `state.subagent_cache`; repeated
calls with the same subagent and same task input return from cache without
rerunning the child.

Override this only when needed:

```elixir
subagents do
  subagent MyApp.Agents.LiveMarketResearcher,
    capture_output: [key: :market_snapshot, dedupe: false]

  subagent MyApp.Agents.SmallClassifier,
    capture_output: [key: :classification, parent_result: :full]
end
```

Use `parent_result: :full` only for small outputs that the supervisor genuinely
needs to read directly. The default acknowledgement keeps the supervisor
context small.

## Named Specialist Tools

The generic `task` tool is convenient, but some applications want named
application tool traces such as `run_narrative_compressor` or
`run_fact_extractor`. In that case, expose normal application tools and have
those tools run the specialist agent themselves. Add
`BeamWeaver.Agent.Middleware.SubagentOutputs` to the supervisor so captured
payloads have mergeable graph channels:

```elixir
defmodule MyApp.SummaryAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  tools do
    tool MyApp.Tools.RunNarrativeCompressor
    tool MyApp.Tools.RunFactExtractor
  end

  middleware do
    use Middleware.TodoList, tool_name: "write_todos"
    use Middleware.SubagentOutputs
  end
end
```

The named tool should return a `BeamWeaver.Graph.Command` that merges the full
JSON-safe output into `:subagent_outputs` and returns only a compact tool
message to the parent model. This gives traces and logs meaningful tool names
while keeping large specialist JSON out of the supervisor transcript.

## Execution Modes

`execution_mode` controls how the child agent runs:

| Mode | Behavior |
| --- | --- |
| `:agent_loop` | Default behavior. The child can use tools and loop until it produces a final answer. |
| `:structured_once` | Runs one model call and enforces a one-call limit. Use this for specialists that should directly produce structured output without autonomous filesystem or TODO loops. |
| `:research_then_generate` | Runs a tool-enabled research pass, then a separate tool-free structured generation pass. Use this for tool-enabled structured specialists. |

Lean specialists need no negative flags. If the child module does not declare
TODO, filesystem, or subagents, those capabilities do not exist:

```elixir
defmodule MyApp.Agents.StageRecommender do
  use BeamWeaver.Agent

  name "stage_recommender"
  description "Recommends the correct pipeline stage."

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  system_prompt "Return the best pipeline stage."
  response_schema MyApp.Schemas.StageRecommendation,
    name: "stage_recommendation",
    strategy: :provider
end
```

If a specialist needs tools before producing structured output, prefer
`:research_then_generate` instead of combining provider-native structured
output with active tools:

```elixir
defmodule MyApp.Agents.DealFactExtractor do
  use BeamWeaver.Agent

  name "deal_fact_extractor"
  description "Researches related records, then emits structured facts."

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  tools do
    tool MyApp.Tools.RelatedDeals
  end

  middleware do
    use BeamWeaver.Agent.Middleware.Filesystem
  end

  system_prompt "Research first, then return structured facts."
  response_schema MyApp.Schemas.FactsOutput, name: "facts_output", strategy: :provider
end
```

The research pass can use the configured tools and middleware. The generation
pass receives the original task plus concise research notes, does not inherit
the parent transcript, and has no tools. This keeps structured-output parsing
bounded and avoids provider tool/JSON interaction problems.

## Runtime Context

Runtime context passed to the parent invocation propagates to synchronous
subagents. Tools inside the child can read it with explicit injection:

```elixir
alias BeamWeaver.Core.Tool

user_lookup =
  Tool.from_function!(
    name: "user_lookup",
    description: "Look up data for the current user.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string"},
        "context" => %{"type" => "object"}
      },
      "required" => ["query", "context"]
    },
    injected: [context: :context],
    handler: fn input, _opts ->
      context = input[:context] || input["context"] || %{}
      user_id = context[:user_id] || context["user_id"]
      query = input[:query] || input["query"]

      "Data for #{user_id}: #{query}"
    end
  )
```

For subagent-specific configuration, either namespace fields in the context map
or model them as separate keys:

```elixir
Agent.invoke(agent, input,
  context: %{
    user_id: "user-123",
    researcher_max_depth: 3,
    fact_checker_strict_mode: true
  }
)
```

When a shared tool needs to know which child called it, inject
`:tool_runtime` and inspect runtime config:

```elixir
Tool.from_function!(
  name: "shared_lookup",
  description: "Look up information with agent-specific behavior.",
  input_schema: %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string"},
      "tool_runtime" => %{"type" => "object"}
    },
    "required" => ["query", "tool_runtime"]
  },
  injected: [tool_runtime: :tool_runtime],
  handler: fn input, _opts ->
    runtime = input[:tool_runtime] || input["tool_runtime"]
    config = runtime.config || %{}

    name =
      get_in(config, [:configurable, :subagent_name]) ||
        get_in(config, ["configurable", "subagent_name"])

    case name do
      "fact-checker" -> MyApp.StrictLookup.search(input["query"] || input[:query])
      _other -> MyApp.GeneralLookup.search(input["query"] || input[:query])
    end
  end
)
```

The parent-side tool message also carries metadata including `:subagent_name`
and `:subagent_type`.

## Streaming

Task subagents are launched from tool calls, so they do not appear as static
subgraph nodes in graph topology. For UI or telemetry projections, collect or
consume agent events and use `BeamWeaver.Agent.Subagent.StreamTransformer`:

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Agent.Subagent.StreamTransformer

{:ok, events} = Agent.stream_events(agent, input)

transformer = StreamTransformer.new(subagent_names: ["researcher"])
{:ok, transformer, _new_handles} = StreamTransformer.process_many(transformer, events)
transformer = StreamTransformer.finalize(transformer)

for handle <- transformer.log do
  IO.inspect(
    %{
      name: handle.graph_name,
      status: handle.status,
      task_input: handle.task_input,
      output: BeamWeaver.Agent.Subagent.RunStream.output(handle)
    },
    label: "subagent"
  )
end
```

For graph subgraphs and agents compiled as graph nodes, use
`BeamWeaver.Stream.Subgraphs` instead.

For message, tool-call, lifecycle, nested subagent, and exact-arrival-order
patterns, see [Event Streaming](event_streaming.md).

## Async Subagents

Use `async_subagents` or `BeamWeaver.Agent.Subagent.AsyncSpec` entries when the
work should run on a remote Agent Protocol server and the parent should not
block until completion.

```elixir
async_subagents do
  async_subagent "remote_research",
    description: "Long-running background research worker.",
    graph_id: "research_graph",
    url: "https://agents.example.com"
end
```

Async subagents expose `start_async_task`, `check_async_task`,
`update_async_task`, `cancel_async_task`, and `list_async_tasks`. They are
separate from the synchronous `task` tool. See
[Async Subagents](async_subagents.md) for transport, lifecycle, state, and
custom client details.

## Best Practices

- Write descriptions that clearly tell the parent when to delegate.
- Keep each subagent's tool set small. This improves focus and narrows the
  permission surface.
- Put output limits in the subagent prompt. Ask for summaries, not raw tool
  dumps.
- Use structured output when the parent needs to parse the result or pass it to
  another tool.
- Use `capture_output` for large structured specialist payloads that should be
  authoritative in state but not re-serialized through the supervisor model.
- Prefer `:research_then_generate` for specialists that need tools and must
  end with structured output.
- Have subagents write large artifacts to the filesystem and return file paths
  plus summaries.
- Use subgraphs rather than task subagents when you need static graph
  introspection, state inspection, or graph-level persistence semantics.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| The parent does the work itself. | Make the subagent `description` more specific and tell the parent prompt when to delegate. |
| The `task` tool is missing. | Configure at least one synchronous subagent. Async-only configuration exposes async tools, not `task`. |
| Context is still bloated. | Instruct subagents to return concise summaries and write raw data to the filesystem. |
| Captured output is missing. | Check `state.subagent_outputs["your_key"]`; the parent model only receives the acknowledgement unless `parent_result: :full` is configured. |
| A captured subagent does not rerun. | Repeated captured calls are cached by subagent name and task input. Use `capture_output: [key: :your_key, dedupe: false]` for volatile work. |
| The wrong subagent is selected. | Make descriptions mutually exclusive, for example separate "quick facts" from "deep research". |
| A subagent cannot access an expected tool. | Check whether `:tools` was set. A list replaces inherited tools; `nil` inherits parent tools. |
| A subagent cannot use `write_todos` or filesystem tools. | Add the corresponding middleware or filesystem configuration to the child agent. These tools are not implicit. |
| A child cannot resume after HITL. | Ensure the parent has a checkpointer and the same thread configuration is used for resume. |

## Unsupported Or Different From Official Deep Agents Docs

| Official Deep Agents docs | BeamWeaver behavior |
| --- | --- |
| `create_deep_agent(..., subagents=[...])` | Use `BeamWeaver.Agent.build/1` or `use BeamWeaver.Agent` with `subagents`. |
| Python dictionary `SubAgent` objects | Use `BeamWeaver.Agent.Subagent.Spec`; keyword lists and maps are accepted for convenience. |
| `CompiledSubAgent(runnable=...)` can wrap a LangGraph runnable | `BeamWeaver.Agent.Subagent.Compiled` expects a BeamWeaver agent module or `%BeamWeaver.Agent.Built{}`. Use graph subgraphs for compiled graph nodes. |
| A default synchronous `general-purpose` subagent is always available | BeamWeaver does not auto-inject it in normal agent builds. Declare a `general-purpose` spec explicitly when wanted. |
| Disable default subagents with `GeneralPurposeSubagentProfile(enabled=False)` | Omit synchronous `subagents`, pass `[]`, or pass `false`. |
| Custom subagents automatically receive the full Deep Agents child capability stack | BeamWeaver child agents compose capabilities explicitly. New code should list the child middleware and tools it needs. Legacy compatibility bundles are covered in the migration guide. |
| Custom subagents do not inherit skills by default | BeamWeaver sync subagents inherit parent skills when `skills` is `nil`; use `skills: []` to opt out. |
| Child run tracing metadata identifies subagent runs | BeamWeaver includes subagent trace metadata such as `subagent_name`, `execution_mode`, `capture_key`, `cache_hit`, and structured-output strategy on child runs and task results; use `StreamTransformer` for subagent stream summaries. |
| Pydantic, `ToolStrategy(...)`, and `ProviderStrategy(...)` schemas | Use JSON Schema maps and `BeamWeaver.Agent.StructuredOutput.tool/2`, `provider/2`, or `auto/2`. |
| Tavily/web search examples are built around Python callables | BeamWeaver has no built-in Tavily tool in this guide. Provide a normal `BeamWeaver.Core.Tool` or `use BeamWeaver.Tool` module. |
| Async subagents are documented on a separate page | BeamWeaver documents them in [Async Subagents](async_subagents.md). |

## Related Guides

- [Composed Agent Capabilities](agent_harness.md)
- [Filesystem](filesystem.md)
- [Skills](skills.md)
- [Context Engineering](context_engineering.md)
- [Async Subagents](async_subagents.md)
- [Subgraphs](subgraphs.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Structured Output](structured_output.md)
- [Runtime](runtime.md)
- [Event Streaming](event_streaming.md)
