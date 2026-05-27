# Subagents

Subagents let a BeamWeaver agent delegate isolated work through the `task`
tool. A subagent receives a fresh message context, runs as a normal BeamWeaver
agent, and returns one final result to the parent. This is useful when a task
would otherwise fill the parent context with intermediate searches, file reads,
tool outputs, or domain-specific reasoning.

Use subagents for multi-step work, specialized tool sets, or tasks that should
use a different model or prompt. Do not use them for simple one-step lookups, or
when the parent must inspect every intermediate message as part of the active
conversation.

{% hint style="info" %}
**Subagents vs Subgraphs**

Task subagents are launched by the model as tool calls. They are not statically
declared graph nodes, so graph introspection cannot discover them before the
tool call happens. Use [Subgraphs](subgraphs.md) when you need a nested graph
that is visible in the compiled topology, state history, and graph-level
inspection APIs.
{% endhint %}

## Enable The Task Tool

Pass synchronous subagent specs with the `subagents` option. BeamWeaver adds a
model-visible `task` tool only when at least one synchronous subagent is
configured.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Agent.Subagent
alias BeamWeaver.Core.Message

{:ok, agent} =
  Agent.build(
    name: "main-agent",
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
    tools: [MyApp.Tools.WebSearch],
    system_prompt: """
    Coordinate the answer. Delegate deep research to the researcher when a
    question needs multiple searches or source synthesis.
    """,
    subagents: [
      Subagent.Spec.new(
        name: "researcher",
        description: "Conducts multi-step web research and returns concise sourced notes.",
        system_prompt: """
        You are a focused research assistant.
        Use web_search when useful.
        Return only essential findings and source URLs.
        Keep the response under 500 words.
        """,
        tools: [MyApp.Tools.WebSearch],
        model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
      )
    ]
  )

{:ok, state} =
  Agent.invoke(agent, %{
    messages: [Message.user("Research recent changes in vector database pricing.")]
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

## Module Agents

The same capability is available in module-defined agents:

```elixir
defmodule MyApp.HarnessedAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Subagent
  alias BeamWeaver.Filesystem

  model BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6")
  filesystem Filesystem.State.new()
  tools [MyApp.Tools.WebSearch]

  subagents [
    Subagent.Spec.new(
      name: "researcher",
      description: "Collect evidence and return concise sourced findings.",
      system_prompt: "Use available tools, cite paths or URLs, and avoid raw dumps.",
      tools: [MyApp.Tools.WebSearch]
    )
  ]
end
```

## Subagent Specs

Use `BeamWeaver.Agent.Subagent.Spec.new/1` for ordinary synchronous subagents.
It accepts keyword lists, atom-keyed maps, and string-keyed maps.

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
| `:response_format` | structured output config | Optional. Configures structured output for the child agent. The parent receives the structured response as JSON text in the `task` tool result. |

Synchronous subagents automatically get useful harness middleware: `write_todos`,
filesystem tools, optional skills, summarization, conversation compaction, tool
call normalization, the subagent's own middleware, and HITL when configured.
The filesystem, filesystem permissions, checkpointer, skills, summarization,
and compaction settings are inherited from the parent unless the subagent spec
overrides them.

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
subagents [
  BeamWeaver.Agent.Subagent.Spec.new(
    name: "general-purpose",
    description: "Handles isolated multi-step work when no specialist fits.",
    system_prompt: """
    You are a general-purpose delegated assistant.
    Complete the task independently and return only the final answer.
    """
  )
]
```

To run without the `task` tool, omit `subagents`, pass `subagents: []`, or pass
`subagents: false`. Async subagents use a separate tool surface and do not
create the synchronous `task` tool by themselves.

## Structured Output

Subagents can use the same structured-output strategies as top-level agents.
When a child agent writes `:structured_response`, the `task` tool returns that
response as JSON to the parent.

```elixir
alias BeamWeaver.Agent.StructuredOutput
alias BeamWeaver.Agent.Subagent

schema = %{
  "title" => "research_findings",
  "type" => "object",
  "required" => ["summary", "confidence", "sources"],
  "properties" => %{
    "summary" => %{"type" => "string"},
    "confidence" => %{"type" => "number"},
    "sources" => %{"type" => "array", "items" => %{"type" => "string"}}
  }
}

researcher =
  Subagent.Spec.new(
    name: "researcher",
    description: "Researches a topic and returns structured findings.",
    system_prompt: "Return a concise structured answer with source URLs.",
    tools: [MyApp.Tools.WebSearch],
    response_format: StructuredOutput.tool(schema)
  )
```

Without `response_format`, the parent receives the last assistant message text
from the child.

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

The parent-side tool message also carries metadata including
`:subagent_name`, `:subagent_type`, and `:lc_agent_type`.

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
async_subagents [
  BeamWeaver.Agent.Subagent.AsyncSpec.new(
    name: "remote-research",
    description: "Long-running background research worker.",
    graph_id: "research_graph",
    url: "https://agents.example.com"
  )
]
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
| The wrong subagent is selected. | Make descriptions mutually exclusive, for example separate "quick facts" from "deep research". |
| A subagent cannot access an expected tool. | Check whether `:tools` was set. A list replaces inherited tools; `nil` inherits parent tools. |
| A child cannot resume after HITL. | Ensure the parent has a checkpointer and the same thread configuration is used for resume. |

## Unsupported Or Different From Official Deep Agents Docs

| Official Deep Agents docs | BeamWeaver behavior |
| --- | --- |
| `create_deep_agent(..., subagents=[...])` | Use `BeamWeaver.Agent.build/1` or `use BeamWeaver.Agent` with `subagents`. |
| Python dictionary `SubAgent` objects | Use `BeamWeaver.Agent.Subagent.Spec`; keyword lists and maps are accepted for convenience. |
| `CompiledSubAgent(runnable=...)` can wrap a LangGraph runnable | `BeamWeaver.Agent.Subagent.Compiled` expects a BeamWeaver agent module or `%BeamWeaver.Agent.Built{}`. Use graph subgraphs for compiled graph nodes. |
| A default synchronous `general-purpose` subagent is always available | BeamWeaver does not auto-inject it in normal agent builds. Declare a `general-purpose` spec explicitly when wanted. |
| Disable default subagents with `GeneralPurposeSubagentProfile(enabled=False)` | Omit synchronous `subagents`, pass `[]`, or pass `false`. |
| Custom subagents do not inherit skills by default | BeamWeaver sync subagents inherit parent skills when `skills` is `nil`; use `skills: []` to opt out. |
| `lc_agent_name` tracing metadata identifies child runs | BeamWeaver uses typed events plus task tool metadata such as `subagent_name`, `subagent_type`, and `lc_agent_type`; use `StreamTransformer` for subagent stream summaries. |
| Pydantic, `ToolStrategy(...)`, and `ProviderStrategy(...)` schemas | Use JSON Schema maps and `BeamWeaver.Agent.StructuredOutput.tool/2`, `provider/2`, or `auto/2`. |
| Tavily/web search examples are built around Python callables | BeamWeaver has no built-in Tavily tool in this guide. Provide a normal `BeamWeaver.Core.Tool` or `use BeamWeaver.Tool` module. |
| Async subagents are documented on a separate page | BeamWeaver documents them in [Async Subagents](async_subagents.md). |

## Related Guides

- [Agent Harness](agent_harness.md)
- [Filesystem](filesystem.md)
- [Skills](skills.md)
- [Context Engineering](context_engineering.md)
- [Async Subagents](async_subagents.md)
- [Subgraphs](subgraphs.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Structured Output](structured_output.md)
- [Runtime](runtime.md)
- [Event Streaming](event_streaming.md)
