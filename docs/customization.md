# Customization

LangChain's Deep Agents customization page centers on one Python entry point,
`create_deep_agent(...)`. BeamWeaver exposes the same agent-building concerns
through two Elixir surfaces:

- `use BeamWeaver.Agent` for stable application modules.
- `BeamWeaver.Agent.build/1` for runtime or config-driven agents.

This page is a map, not a replacement for the detailed guides. Use it when you
are porting examples from the official Deep Agents docs and need to know which
BeamWeaver option, macro, or guide owns each concept.

{% hint style="info" %}
**No Separate Deep Agent Type**

A "deep" agent in BeamWeaver is a normal graph-backed agent with additional
model options, tools, middleware, filesystem backends, permissions, memory,
skills, subagents, structured output, and runtime dependencies. The long-form
composed capability behavior is documented in [Composed Agent Capabilities](agent_harness.md).
{% endhint %}

## Option Map

| Python `create_deep_agent` option | BeamWeaver surface | Details |
| --- | --- | --- |
| `model` | `model` / `:model`, `model_opts`, `BeamWeaver.Models.init_chat_model!/2` | [Agents](agents.md), [Models](models.md) |
| `tools` | `tools` / `:tools`, `%BeamWeaver.Core.Tool{}`, `use BeamWeaver.Tool` | [Tools](tools.md) |
| `system_prompt` | `system_prompt` / `:system_prompt` | [Agents](agents.md), [Profiles](profiles.md) |
| `middleware` | `middleware` / `:middleware`, `BeamWeaver.Agent.Middleware` | [Middleware](middleware.md), [Custom Middleware](custom_middleware.md), [Prebuilt Middleware](prebuilt_middleware.md) |
| `subagents` | `subagents`, `async_subagents` | [Subagents](subagents.md), [Async Subagents](async_subagents.md) |
| `skills` | `skills` | [Skills](skills.md) |
| `memory` | `memory`, checkpoint-backed short-term memory, store-backed long-term memory | [Memory](memory.md), [Short-Term Memory](short_term_memory.md), [Long-Term Memory](long_term_memory.md) |
| `permissions` | `filesystem_permissions`; runtime alias `:permissions` | [Filesystem Permissions](permissions.md) |
| `backend` | `filesystem`; runtime alias `:backend` | [Filesystem](filesystem.md), [Sandboxes](sandboxes.md) |
| `interrupt_on` | `interrupt_on`, graph interrupts, `BeamWeaver.Agent.Middleware.HumanInTheLoop` | [Human-In-The-Loop](human_in_the_loop.md) |
| `response_format` | `response_format` / `:response_format` | [Structured Output](structured_output.md) |
| `context_schema` | `context_schema` / `:context_schema`; invocation `context:` | [Runtime](runtime.md), [Agents](agents.md) |
| `checkpointer` | `checkpointer` / `:checkpointer` | [Persistence](persistence.md), [Durable Execution](durable_execution.md) |
| `store` | `store` / `:store`, `BeamWeaver.Memory.Store` adapters | [Persistence](persistence.md), [Long-Term Memory](long_term_memory.md) |
| `debug` | `debug` / `:debug`; typed debug events and logging | [Event Streaming](event_streaming.md), [Tracing](tracing.md) |
| `name` | `name` / `:name` | [Agents](agents.md) |
| `cache` | `cache` / `:cache`, `BeamWeaver.Cache` adapters | [Adapters](adapters.md) |

BeamWeaver also exposes agent options that are not a direct Python parameter:
`model_opts`, `validate_tools`, `input_schema`, `output_schema`,
`interrupt_before`, `interrupt_after`, `recursion_limit`,
`compact_conversation`, `overflow_recovery`, `prompt_caching`,
`exclude_tools`, and `tool_descriptions`.

## Configuration Areas

The official customization page is organized around the knobs below. In
BeamWeaver, each knob is an agent field, a runtime
`BeamWeaver.Agent.build/1` option, or a middleware/backend choice.

### Model

Pass either a provider-prefixed model string or an initialized chat model:

```elixir
model "openai:gpt-5.4", timeout: 120_000

# or
model BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6")
```

Runtime agents use the matching options:

```elixir
BeamWeaver.Agent.build(
  model: "openai:gpt-5.4",
  model_opts: [timeout: 120_000]
)
```

See [Models](models.md) and the provider pages for supported provider strings
and model-specific options.

### Tools

Pass tool modules, `%BeamWeaver.Core.Tool{}` structs, or functions converted
through the tool APIs:

```elixir
tools do
  tool MyApp.Tools.SearchDocs
  tool MyApp.Tools.CreateTicket
end
```

Use [Tools](tools.md) for tool schemas, injected runtime values, artifacts, and
provider normalization.

### System Prompt

Use `system_prompt` for task and product instructions. Middleware that
contributes special tools, such as filesystem, skills, or memory middleware,
adds its own model guidance around that prompt during the model request.

```elixir
system_prompt "You are a release-risk analyst. Cite concrete evidence."
```

For provider/model-specific prompt changes, prefer explicit agent config,
middleware, or profiles instead of copying the built-in Deep Agents prompt into
every agent.

### Middleware

BeamWeaver middleware is the extension point for lifecycle hooks, dynamic prompt
edits, retry/fallback behavior, PII handling, tool-call limits, and human
review:

```elixir
middleware do
  use BeamWeaver.Agent.Middleware.ModelRetry, max_attempts: 3
  use BeamWeaver.Agent.Middleware.TodoList, tool_name: "write_todos"
end
```

See [Middleware](middleware.md), [Prebuilt Middleware](prebuilt_middleware.md),
and [Custom Middleware](custom_middleware.md).

### Interpreters And Code Execution

BeamWeaver does not expose the Python QuickJS interpreter middleware as a
separate first-class option. Use one of these instead:

- Custom tools for narrow, application-owned computation.
- `BeamWeaver.Filesystem.LocalShell` or another executable filesystem backend
  when the agent needs an `execute` tool.
- Sandbox-backed filesystems for isolated command execution.

See [Filesystem](filesystem.md), [Sandboxes](sandboxes.md), and
[Composed Agent Capabilities](agent_harness.md#code-execution).

### Subagents

Use `subagents` for synchronous `task` delegation and `async_subagents` for
remote Agent Protocol work:

```elixir
subagents do
  subagent MyApp.Agents.Researcher
end
```

The child agent module owns its prompt, tools, middleware, and schema.

See [Subagents](subagents.md) and [Async Subagents](async_subagents.md).

### Backends And Filesystems

Official Deep Agents calls this layer "backends." BeamWeaver's public agent
field is `filesystem`; runtime `backend:` remains accepted as a compatibility
alias.

```elixir
filesystem BeamWeaver.Filesystem.State.new()
```

Use `BeamWeaver.Filesystem.Composite` when different virtual path prefixes
should route to different storage backends. Use sandbox filesystem adapters
when the agent should run commands outside the host process.

### Human-In-The-Loop

Set `interrupt_on` to pause before sensitive tool calls:

```elixir
interrupt_on %{
  "edit_file" => true,
  "send_email" => %{allowed_decisions: [:approve, :reject]}
}
```

Human review requires checkpointing so the interrupted run can be resumed. See
[Human-In-The-Loop](human_in_the_loop.md).

### Skills

Use `skills` to expose `SKILL.md` metadata stored in the configured filesystem.
Skills are progressively disclosed: the startup prompt lists available skills,
and the model reads full skill files only when relevant.

```elixir
skills ["/skills"]
```

See [Skills](skills.md).

### Memory

Use `memory true` to load `/AGENTS.md`, or pass explicit memory file paths:

```elixir
memory ["/AGENTS.md", "/project/AGENTS.md"]
```

This is filesystem-backed agent memory. It is separate from short-term graph
state and long-term application stores. See [Memory](memory.md),
[Short-Term Memory](short_term_memory.md), and [Long-Term Memory](long_term_memory.md).

### Profiles

BeamWeaver separates profiles by concern:

- Model profiles describe model capabilities and tokenizer defaults.
- Provider profiles supply model-construction defaults.
- Capability profiles package capability defaults for custom composed agents.

See [Profiles](profiles.md).

### Structured Output

Use `response_schema/2` for the agent's final structured result:

```elixir
response_schema MyApp.Schemas.Contact,
  name: "contact",
  strategy: :tool
```

Final parsed data is returned as `:structured_response` in the agent state. See
[Structured Output](structured_output.md).

## Runtime-Built Agent

Use `BeamWeaver.Agent.build/1` when the agent is assembled from configuration,
tenant data, or another runtime source:

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Agent.Middleware
alias BeamWeaver.Agent.Subagent
alias BeamWeaver.Checkpoint
alias BeamWeaver.Core.Message
alias BeamWeaver.Filesystem
alias BeamWeaver.Filesystem.Permission
alias BeamWeaver.Memory

{:ok, agent} =
  Agent.build(
    name: "research_agent",
    model: "anthropic:claude-sonnet-4-6",
    model_opts: [
      timeout: 120_000,
      max_output_tokens: 2_000
    ],
    tools: [MyApp.Tools.Search],
    system_prompt: "You are a careful research assistant.",
    middleware: [
      {Middleware.ModelRetry, max_attempts: 3},
      {Middleware.TodoList, tool_name: "write_todos"}
    ],
    filesystem: Filesystem.State.new(),
    filesystem_permissions: [
      Permission.new(operations: [:read, :write], paths: ["/secrets/**"], mode: :deny),
      Permission.new(operations: [:read, :write], paths: ["/workspace/**"], mode: :allow)
    ],
    skills: ["/skills"],
    memory: ["/AGENTS.md"],
    subagents: [
      Subagent.Spec.new(
        name: "evidence_collector",
        description: "Collect source-backed facts without editing files.",
        system_prompt: "Return concise findings with file paths."
      )
    ],
    interrupt_on: %{"edit_file" => true},
    response_format: MyApp.Schemas.ResearchSummary.schema(),
    context_schema: %{
      user_id: %{type: :string, required: true}
    },
    checkpointer: Checkpoint.ETS.new(),
    store: Memory.ETS.new(),
    debug: true,
    recursion_limit: 10_000
  )

Agent.invoke(
  agent,
  %{messages: [Message.user("Summarize the release risk.")]},
  context: %{user_id: "user-123"},
  config: %{"configurable" => %{"thread_id" => "thread-123"}}
)
```

The `model_opts[:timeout]` value is important for long model calls. It sets the
generated agent model node's graph timeout and also flows into provider model
construction when the model is specified as a provider string. Without an
explicit model timeout, the generated model node falls back to the graph node
default. See [Agents](agents.md#model) and [Fault Tolerance](fault_tolerance.md)
for the timeout precedence.

## Module-Defined Agent

Use a module-defined agent for stable application code. It exposes the same
fields as macros:

```elixir
defmodule MyApp.ResearchAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Permission
  alias BeamWeaver.Memory

  name "research_agent"
  model "anthropic:claude-sonnet-4-6", timeout: 120_000, max_output_tokens: 2_000

  tools do
    tool MyApp.Tools.Search
  end

  system_prompt "You are a careful research assistant."

  middleware do
    use Middleware.ModelRetry, max_attempts: 3
    use Middleware.TodoList, tool_name: "write_todos"
  end

  filesystem Filesystem.State.new()

  filesystem_permissions [
    Permission.new(operations: [:read, :write], paths: ["/secrets/**"], mode: :deny),
    Permission.new(operations: [:read, :write], paths: ["/workspace/**"], mode: :allow)
  ]

  skills ["/skills"]
  memory ["/AGENTS.md"]

  subagents do
    subagent MyApp.Agents.EvidenceCollector
  end

  interrupt_on %{"edit_file" => true}
  response_schema MyApp.Schemas.ResearchSummary

  context_schema do
    field :user_id, :string, required: true
  end

  checkpointer Checkpoint.ETS.new()
  store Memory.ETS.new()
  debug true
  recursion_limit 10_000
end
```

Module agents and runtime-built agents compile through the same
`BeamWeaver.Agent.Spec` and graph compiler. Prefer modules when the agent shape
belongs to application code; use `BeamWeaver.Agent.build/1` when the shape is
data.

## Prompt And Profiles

The normal customization path is direct configuration:

- Put product or task instructions in `system_prompt`.
- Use `tool_descriptions` and `exclude_tools` when you need to adjust the
  model-visible tool surface.
- Use `middleware` for dynamic prompts, model retries, fallbacks, call limits,
  PII handling, context editing, and custom lifecycle hooks.

BeamWeaver also has profiles, but they are intentionally split by concern:

- Provider profiles apply model-construction defaults for provider/model
  strings.
- Model profiles describe model capabilities such as context window, tool
  calling, streaming, and structured output support.
- Capability profiles mirror Deep Agents profile data for custom composed agent
  code, but normal agent builds do not automatically overlay them.

See [Profiles](profiles.md) for the exact behavior and differences from the
official Deep Agents profile API.

## Differences From Python Examples

| Python docs pattern | BeamWeaver shape |
| --- | --- |
| One `create_deep_agent(...)` call | `use BeamWeaver.Agent` module macros or `BeamWeaver.Agent.build/1` options. |
| Provider packages installed independently | Use documented native providers: OpenAI, Anthropic, Google, xAI, fake, and replay-backed tests. |
| Python decorators such as `@wrap_model_call` | Implement `BeamWeaver.Agent.Middleware` callbacks or use prebuilt middleware modules. |
| Dataclass or typed `Runtime[Context]` | Pass `context:` maps and validate with `context_schema`. |
| Python `BaseStore` and checkpointers | Pass `BeamWeaver.Memory.Store` and `BeamWeaver.Checkpoint.Saver` adapters explicitly. |
| LangChain `stream_events(..., version="v3")` projection object | Use versionless typed envelope streams from `BeamWeaver.Agent.stream_events/3`. |
| QuickJS interpreter middleware | Use tools, executable filesystem backends, or sandbox-backed filesystems when code execution is required. |
| Automatic hosted deployment infrastructure | Configure checkpointers, stores, cache, tracing exporters, auth boundaries, and sandbox lifecycle in Elixir. |

## Related

- [Composed Agent Capabilities](agent_harness.md)
- [Agents](agents.md)
- [Models](models.md)
- [Tools](tools.md)
- [Middleware](middleware.md)
- [Runtime](runtime.md)
- [Structured Output](structured_output.md)
- [Filesystem](filesystem.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Skills](skills.md)
- [Memory](memory.md)
- [Profiles](profiles.md)
