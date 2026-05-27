# Prebuilt Middleware

BeamWeaver ships common agent middleware as Elixir modules under
`BeamWeaver.Agent.Middleware`. Middleware entries can be modules, structs, or
`{module, opts}` tuples:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")
  tools [MyApp.Tools.SearchDocs]

  middleware [
    {Middleware.ModelRetry, max_retries: 2, initial_delay: 100},
    {Middleware.ToolSelection, deny: ["internal_admin_tool"]},
    {Middleware.PII, detectors: [:email], strategy: :redact}
  ]
end
```

Runtime-built agents use the same values:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini"),
    tools: [MyApp.Tools.SearchDocs],
    middleware: [
      {BeamWeaver.Agent.Middleware.ToolCallLimit, run_limit: 8}
    ]
  )
```

{% hint style="info" %}
**Native Middleware Shape**

The Python docs use classes such as `SummarizationMiddleware(...)` passed to
`create_agent`. BeamWeaver keeps the same execution ideas, but the public API is
Elixir data. If the module implements `new/1`, BeamWeaver calls it for
`{module, opts}` entries; otherwise the middleware can be a module or struct
directly.
{% endhint %}

## Available Middleware

| Need | BeamWeaver path |
| --- | --- |
| Dynamic system prompts | `BeamWeaver.Agent.Middleware.DynamicPrompt` |
| Tool filtering or model-selected tools | `BeamWeaver.Agent.Middleware.ToolSelection` |
| Model retries | `BeamWeaver.Agent.Middleware.ModelRetry` |
| Tool retries | `BeamWeaver.Agent.Middleware.ToolRetry` |
| Model fallbacks | `BeamWeaver.Agent.Middleware.ModelFallback` |
| Model call limits | `BeamWeaver.Agent.Middleware.ModelCallLimit` |
| Tool call limits | `BeamWeaver.Agent.Middleware.ToolCallLimit` |
| Conversation summarization | `BeamWeaver.Agent.Middleware.Summarization` |
| Structured-output retry feedback | `BeamWeaver.Agent.Middleware.StructuredOutputRetry` |
| Human review before tools | `BeamWeaver.Agent.Middleware.HumanInTheLoop` |
| Context editing | `BeamWeaver.Agent.Middleware.ContextEditing` |
| PII detection and editing | `BeamWeaver.Agent.Middleware.PII` |
| TODO planning | `BeamWeaver.Agent.Middleware.TodoList` |
| Virtual filesystem tools | `BeamWeaver.Agent.Middleware.Filesystem` |
| Progressive-disclosure skills | `BeamWeaver.Agent.Middleware.Skills` |
| AGENTS.md memory files | `BeamWeaver.Agent.Middleware.Memory` |
| Deep Agents subagent task tool | `BeamWeaver.Agent.Middleware.Subagents` |
| Remote async subagent tools | `BeamWeaver.Agent.Middleware.AsyncSubagents` |
| Manual conversation compaction | `BeamWeaver.Agent.Middleware.CompactConversation` |
| Context-overflow recovery | `BeamWeaver.Agent.Middleware.OverflowRecovery` |
| Anthropic prompt caching | `BeamWeaver.Agent.Middleware.PromptCaching` |
| Policy-governed shell session | `BeamWeaver.Agent.Middleware.ShellTool` |
| Tool-result emulation for tests | `BeamWeaver.Agent.Middleware.ToolEmulator` |

## Summarization

`BeamWeaver.Agent.Middleware.Summarization` summarizes older messages before a
model call and keeps recent context in the agent state.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.Summarization,
   model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini"),
   trigger: {:tokens, 4_000},
   keep: {:messages, 20}}
]
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:model` | Required chat model used to create summaries. |
| `:trigger` | `{:messages, n}`, `{:tokens, n}`, `{:fraction, f}`, a list of triggers, or `nil`. |
| `:keep` | `{:messages, n}`, `{:tokens, n}`, `{:fraction, f}`, or `nil`. |
| `:token_counter` | `:approximate`, a counting function, or a model/counter accepted by `BeamWeaver.Core.LanguageModel.count_tokens/2`. |
| `:summary_prompt` | Prompt template containing `{messages}`. |
| `:summary_prefix` | Prefix for the replacement system message. |
| `:trim_tokens_to_summarize` | Maximum summary-input size before the summary model is called. |

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.Summarization,
   model: summary_model,
   trigger: [{:tokens, 3_000}, {:messages, 12}],
   keep: {:tokens, 1_500},
   summary_prompt: "Summarize the relevant facts:\n\n{messages}"}
]
```

{% hint style="warning" %}
**Fractional Limits Need Model Profiles**

Python LangChain reads model profile data dynamically when using fractional
summary limits. BeamWeaver can use `{:fraction, value}` only when the model has
`profile.max_input_tokens`; otherwise the middleware raises at construction
time. Use token or message thresholds when the profile does not include a
context size.
{% endhint %}

## Human-In-The-Loop

`BeamWeaver.Agent.Middleware.HumanInTheLoop` interrupts after the model emits
configured tool calls and before those tools execute. The interrupted run can be
resumed with approve, edit, reject, or respond decisions.

```elixir
defmodule MyApp.ReviewedAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.HumanInTheLoop

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  tools [MyApp.Tools.ReadEmail, MyApp.Tools.SendEmail]

  middleware [
    {HumanInTheLoop,
     interrupt_on: %{
       "send_email" => %{allowed_decisions: [:approve, :edit, :reject]},
       "read_email" => false
     },
     tools: [MyApp.Tools.ReadEmail, MyApp.Tools.SendEmail]}
  ]
end
```

Human review requires a checkpointer because the run pauses and resumes from a
checkpoint:

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "email-thread-1"}}

case MyApp.ReviewedAgent.invoke(
       %{messages: [Message.user("Send the update.")]},
       checkpointer: checkpointer,
       config: config
     ) do
  {:interrupted, interrupt} ->
    IO.inspect(interrupt.value.action_requests)

    MyApp.ReviewedAgent.resume(
      %{decisions: [%{type: :approve}]},
      checkpointer: checkpointer,
      config: config
    )

  other ->
    other
end
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:interrupt_on` | Map of tool names to `true`, `false`, or review config. |
| `:description_prefix` | Default prefix for generated review descriptions. |
| `:tools` | Tool list used to validate edited arguments against tool schemas. |

{% hint style="info" %}
**Decision Payloads Are Elixir Data**

The Python examples show `Command(resume=...)` objects. BeamWeaver uses
`BeamWeaver.Agent.resume/3` or `BeamWeaver.Agent.resume_review/3` with maps or
`%BeamWeaver.Agent.Middleware.HumanInTheLoop.Decision{}` structs. The interrupt
payload is also typed Elixir data and appears in event streams as
`%BeamWeaver.Stream.Envelope{}` events.
{% endhint %}

## Model And Tool Call Limits

Use call limits to prevent runaway loops and enforce local cost controls.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ModelCallLimit,
   thread_limit: 20,
   run_limit: 6,
   exit_behavior: :end},
  {BeamWeaver.Agent.Middleware.ToolCallLimit,
   tool_name: "search",
   thread_limit: 10,
   run_limit: 3,
   exit_behavior: :continue}
]
```

Model-call options:

| Option | Meaning |
| --- | --- |
| `:thread_limit` | Max model calls across a checkpointed thread. Defaults to `10` when omitted. |
| `:run_limit` | Max model calls in one invocation. |
| `:exit_behavior` | `:error` or `:end`. |
| `:max_calls` | Compatibility alias for `:thread_limit`. |

Tool-call options:

| Option | Meaning |
| --- | --- |
| `:tool_name` | Optional tool name to limit. Omit for global limits. |
| `:thread_limit` | Max matching tool calls across a checkpointed thread. Defaults to `10` when omitted. |
| `:run_limit` | Max matching tool calls in one invocation. |
| `:exit_behavior` | `:continue`, `:error`, or `:end`. |
| `:message` | Tool message content for blocked calls. |
| `:max_calls` | Compatibility alias for `:thread_limit`. |

{% hint style="warning" %}
**Default Limits Differ From Python**

The Python docs describe unset limits as no limit. BeamWeaver's call-limit
middleware defaults `thread_limit` to `10` for safety. Set `thread_limit: nil`
when you only want a run-scoped limit. At least one of `thread_limit` or
`run_limit` must be configured.
{% endhint %}

## Model Fallback

`BeamWeaver.Agent.Middleware.ModelFallback` tries alternate models when the
primary model returns a tagged error.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ModelFallback,
   fallbacks: [
     BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini"),
     BeamWeaver.Models.init_chat_model!("anthropic:claude-haiku-4-5")
   ],
   retry_on: [:rate_limit, :timeout, :provider_error]}
]
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:fallbacks` | Models to try in order. |
| `:models` | Compatibility alias for `:fallbacks`. |
| `:retry_on` | `:error`, `:all`, an error type atom, a list of error type atoms, or a one-argument predicate. |

## Retries

Model and tool retry middleware share `BeamWeaver.RetryPolicy`.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ModelRetry,
   max_retries: 3,
   initial_delay: 100,
   max_delay: 5_000,
   backoff: 2.0,
   jitter: true,
   retry_on: [:rate_limit, :timeout],
   on_failure: :continue},
  {BeamWeaver.Agent.Middleware.ToolRetry,
   tools: ["search"],
   max_retries: 2,
   retry_on: :tool_error,
   on_failure: :continue}
]
```

Useful retry options:

| Option | Meaning |
| --- | --- |
| `:max_retries` | Compatibility option translated to `max_attempts: max_retries + 1`. |
| `:max_attempts` | Total attempts including the first call. |
| `:initial_delay` | Delay before first retry. Integers are milliseconds; floats are seconds. |
| `:max_delay` | Maximum retry delay. Integers are milliseconds; floats are seconds. |
| `:backoff` | Exponential backoff multiplier. Use `0` for constant delay. |
| `:jitter` | `false`, `true`, or a non-negative integer jitter window in milliseconds. |
| `:retry_on` | `:error`, `:all`, `:transient`, an error type atom, list of types, predicate, or `{module, function, extra_args}`. |
| `:on_failure` | `:error`, `:continue`, or a one-argument formatter function. |

`ToolRetry` also accepts `:tools`, a list of tool names, atoms, or tool structs.

Retry and fallback policies are agent middleware concerns. Provider model values
do not wrap themselves with retry or fallback policies; keep resilience at this
middleware boundary so tracing, call limits, interrupts, and tool middleware
share the same runtime context.

{% hint style="info" %}
**Tagged Errors Instead Of Python Exceptions**

Python middleware filters exception classes. BeamWeaver providers, tools, and
middleware return `{:error, %BeamWeaver.Core.Error{type: type}}`. Retry filters
therefore match error types or predicates over the tagged error value.
{% endhint %}

## PII Detection

`BeamWeaver.Agent.Middleware.PII` detects and edits text in user input, model
output, and tool results.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.PII,
   type: :email,
   strategy: :redact,
   apply_to_input: true},
  {BeamWeaver.Agent.Middleware.PII,
   type: :credit_card,
   strategy: :mask,
   apply_to_input: true,
   apply_to_output: true}
]
```

Built-in detector types are `:email`, `:credit_card`, `:ip`, `:mac_address`,
and `:url`. Strategies are `:block`, `:redact`, `:mask`, and `:hash`.

Custom detectors can be regex strings, one-argument functions, or MFA tuples:

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.PII,
   type: :api_key,
   detector: ~S/sk-[A-Za-z0-9]{32}/,
   strategy: :block},
  {BeamWeaver.Agent.Middleware.PII,
   type: :ssn,
   detector: &MyApp.PII.detect_ssn/1,
   strategy: :hash}
]
```

Detector functions return match maps with `:text` or `:value`, `:start`, and
`:end` byte offsets:

```elixir
def detect_ssn(content) do
  Regex.scan(~r/\d{3}-\d{2}-\d{4}/, content, return: :index)
  |> Enum.map(fn [{start, length}] ->
    %{text: binary_part(content, start, length), start: start, end: start + length}
  end)
end
```

{% hint style="warning" %}
**PII Detection Is Local And Pattern-Based**

BeamWeaver's built-in PII middleware uses local detectors. It does not call an
external DLP service or provider moderation API. For OpenAI moderation, use
`BeamWeaver.OpenAI.ModerationMiddleware`; for stronger compliance needs, add a
custom detector or middleware backed by your approved service. See
[Guardrails](guardrails.md) for layering PII detection, moderation, HITL, and
custom policy checks.
{% endhint %}

## Todo List

`BeamWeaver.Agent.Middleware.TodoList` adds a native `todo` tool and prompt
guidance. The tool updates graph state through commands, and the middleware
prevents multiple parallel TODO writes from the same model response.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.TodoList,
   state_key: :todos,
   tool_name: "todo",
   tool_description: "Maintain the working TODO list.",
   system_prompt: "Use the todo tool for multi-step tasks."}
]
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:state_key` | Agent state key that stores TODO items. |
| `:tool_name` | Tool name exposed to the model. |
| `:tool_description` | Tool description sent in the tool schema. |
| `:system_prompt` | Prompt text appended to model calls. |

## Tool Selection

`BeamWeaver.Agent.Middleware.ToolSelection` can filter tools deterministically
or ask a model to select relevant tools for the current request.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ToolSelection,
   allow: ["search_docs", "get_ticket"],
   deny: ["internal_admin_tool"]},
  {BeamWeaver.Agent.Middleware.ToolSelection,
   model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini"),
   max_tools: 3,
   always_include: ["search_docs"]}
]
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:allow` | Names that may be sent to the model. |
| `:deny` | Names to remove. |
| `:tags` | Keep tools with matching `Tool.tags/1`. |
| `:metadata` | Keep tools whose metadata contains matching key/value pairs. |
| `:predicate` | Two-argument filter predicate over the tool and model request. |
| `:tools` | Static or dynamic tools added by middleware. |
| `:model` | Selection model. Supplying this enables model-based selection. |
| `:system_prompt` | Selection prompt. |
| `:max_tools` | Maximum selected tools. |
| `:always_include` | Tool names always included after selection. |

{% hint style="info" %}
**LLM Tool Selector Name**

Python calls this `LLMToolSelectorMiddleware`. BeamWeaver exposes the same
capability through `ToolSelection`; model-based selection is enabled when you
provide `:model`, `:system_prompt`, `:max_tools`, or `:always_include`.
{% endhint %}

## Tool Emulator

`BeamWeaver.Agent.Middleware.ToolEmulator` replaces selected tool executions
with model-generated tool messages. Use it for tests, demos, and early
prototypes.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ToolEmulator,
   tools: ["get_weather"],
   model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")}
]
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:tools` | Tool names, atoms, or tool structs to emulate. Omit to emulate every tool. |
| `:model` | Model used to write the emulated tool result. Defaults to a fake model. |
| `:prompt_template` | Template containing `{tool}`, `{description}`, and `{args}`. |

## Context Editing

`BeamWeaver.Agent.Middleware.ContextEditing` edits message history before model
calls. The built-in edit clears older tool outputs while preserving recent tool
context.

```elixir
alias BeamWeaver.Agent.Middleware.ContextEditing

middleware [
  {ContextEditing,
   edits: [
     ContextEditing.ClearToolUses.new(
       trigger: 100_000,
       keep: 3,
       clear_at_least: 2_000,
       clear_tool_inputs: false,
       exclude_tools: ["audit_log"],
       placeholder: "[cleared]"
     )
   ],
   token_count_method: :approximate}
]
```

You can also provide a custom editor:

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ContextEditing,
   editor: fn messages -> Enum.take(messages, -12) end}
]
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:edits` | List of edit structs or functions. Defaults to `ClearToolUses`. |
| `:token_count_method` | `:approximate` or `:model`. |
| `:editor` | Custom editor function or MFA used as a state hook. |

`ClearToolUses` accepts `:trigger`, `:clear_at_least`, `:keep`,
`:clear_tool_inputs`, `:exclude_tools`, and `:placeholder`.

## Structured Output Retry

`BeamWeaver.Agent.Middleware.StructuredOutputRetry` adds feedback and retries
when a model response cannot be parsed or validated as structured output.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.StructuredOutputRetry,
   max_retries: 2,
   feedback: "Fix the structured output. Error: {error}"}
]
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:max_retries` | Number of retry turns after the first structured-output failure. |
| `:feedback` | Feedback template or one-argument function. |
| `:retry_on` | Error type atom, list, `MapSet`, `:all`, or predicate over error type. |

See [Structured Output](structured_output.md) for schemas and model-level
structured output.

## Shell Tool

`BeamWeaver.Agent.Middleware.ShellTool` adds a policy-governed shell tool backed
by a supervised session process for the agent run.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ShellTool,
   workspace_root: File.cwd!(),
   policy: [
     allow: ["git status", "mix test"],
     deny: [~r/--force/],
     timeout: 10_000,
     max_output_bytes: 20_000,
     redactions: [{~r/sk-[A-Za-z0-9]+/, "[REDACTED_API_KEY]"}]
   ],
   startup_commands: ["pwd"],
   shutdown_commands: [],
   tool_name: "shell"}
]
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:workspace_root` | Base directory for the shell session. |
| `:policy` | `BeamWeaver.ShellPolicy` options. Defaults to an allow-all policy only when not provided. |
| `:startup_commands` | Commands run when the session starts. |
| `:shutdown_commands` | Commands run before the session shuts down. |
| `:tool_name` | Shell tool name. |
| `:tool_description` | Shell tool description. |
| `:state_key` | Private state key storing the session PID. |

`BeamWeaver.ShellPolicy` supports `:allow`, `:deny`, `:cwd`, `:env`,
`:env_allowlist`, `:timeout`, `:max_output_bytes`, `:stderr`, `:empty_output`,
`:truncation_indicator`, `:redactions`, and a custom `:executor`.

{% hint style="warning" %}
**Shell Isolation Is Policy-Based**

Python documents `HostExecutionPolicy`, `DockerExecutionPolicy`, and
`CodexSandboxExecutionPolicy`. BeamWeaver does not expose those classes. It uses
`BeamWeaver.ShellPolicy` plus a pluggable executor module. For stronger
isolation, provide an executor that runs commands in your chosen container,
VM, or remote sandbox.
{% endhint %}

## File Search

Python documents file search as middleware that adds `glob_search` and
`grep_search` tools. BeamWeaver exposes file and document search as a normal
tool: `BeamWeaver.Tools.FileSearch`.

```elixir
tools [
  BeamWeaver.Tools.FileSearch.new(
    roots: ["docs"],
    include: ["**/*.md"],
    exclude: ["**/.git/**"],
    include_hidden?: false,
    max_results: 10,
    max_file_bytes: 1_000_000,
    snippet_bytes: 240,
    query_mode: :literal,
    output_mode: :content
  )
]
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:retriever` | Optional retriever source instead of filesystem roots. |
| `:roots` | Filesystem roots. Required when no retriever is provided. |
| `:include` / `:exclude` | Glob patterns. |
| `:include_hidden?` | Whether hidden paths can be searched. |
| `:max_results` | Maximum results returned. |
| `:max_file_bytes` | Maximum searchable file size. |
| `:snippet_bytes` | Bytes included around a content match. |
| `:query_mode` | `:literal` or `:regex`. |
| `:output_mode` | `:content` or `:count`. |
| `:sort` | `:path` or `:mtime_desc`. |

{% hint style="info" %}
**Tool Instead Of Middleware**

BeamWeaver does not need middleware to expose local search. Adding
`BeamWeaver.Tools.FileSearch` to the agent's `tools` list gives the model the
capability directly, while `ToolSelection`, `ToolRetry`, `ToolCallLimit`, and
`HumanInTheLoop` can still govern that tool.
{% endhint %}

## Filesystem And Subagents

Deep Agents-style filesystem and subagent capabilities are integrated into
normal BeamWeaver agents:

```elixir
defmodule MyApp.HarnessedAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Subagent
  alias BeamWeaver.Filesystem

  model BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6")
  filesystem Filesystem.State.new()

  subagents [
    Subagent.Spec.new(
      name: "researcher",
      description: "Collect evidence without changing files.",
      system_prompt: "Return concise findings with file paths."
    )
  ]

  middleware [
    {Middleware.TodoList, tool_name: "write_todos"}
  ]
end
```

`BeamWeaver.Agent.Middleware.Filesystem` contributes `ls`, `read_file`,
`write_file`, `edit_file`, `glob`, `grep`, and, for executable backends,
`execute`. `BeamWeaver.Agent.Middleware.Subagents` contributes the `task` tool
for explicit synchronous subagent specs. Async subagents expose
`start_async_task`, `check_async_task`, `update_async_task`,
`cancel_async_task`, and `list_async_tasks`.

See [Filesystem](filesystem.md) for the virtual filesystem API and
[Filesystem Permissions](permissions.md) for path allow/deny rules. See
[Subagents](subagents.md) for delegation configuration, structured subagent
results, and context propagation. See [Async Subagents](async_subagents.md) for
background task lifecycle, remote clients, and `:async_tasks` state.

{% hint style="info" %}
**Graph Subgraphs vs Task Subagents**

BeamWeaver's native orchestration isolation primitive is still the
graph/subgraph boundary. Use `BeamWeaver.Agent.compiled_graph/2` when you want a
nested agent to travel as a graph node, and use
[Event Streaming](event_streaming.md) to observe nested graph events.
{% endhint %}

## Provider-Specific Middleware

Provider-specific behavior is intentionally narrow and lives near provider
adapters.

### OpenAI Moderation

`BeamWeaver.OpenAI.ModerationMiddleware` calls OpenAI's moderation endpoint at
input, output, and optional tool-result boundaries.

```elixir
middleware [
  BeamWeaver.OpenAI.ModerationMiddleware.new(
    model: "omni-moderation-latest",
    check_input: true,
    check_output: true,
    check_tool_results: false,
    exit_behavior: :end,
    violation_message: "I can't comply because this was flagged for {categories}."
  )
]
```

Useful options:

| Option | Meaning |
| --- | --- |
| `:model` | OpenAI moderation model. |
| `:check_input` | Moderate latest user input before the model call. |
| `:check_output` | Moderate latest assistant output after the model call. |
| `:check_tool_results` | Moderate tool messages before the model call. |
| `:exit_behavior` | `:error`, `:end`, or `:replace`. |
| `:violation_message` | Template with `{categories}`, `{category_scores}`, and `{original_content}`. |
| `:client` and OpenAI client opts | Custom client or client construction options. |

### Anthropic Helpers

BeamWeaver includes Anthropic call-option helpers:

- `BeamWeaver.Anthropic.Middleware.PromptCaching`
- `BeamWeaver.Anthropic.Middleware.Bash`
- `BeamWeaver.Anthropic.Middleware.FileSearch`
- `BeamWeaver.Anthropic.Middleware.AnthropicTools`

These helpers produce provider call options, such as server-tool declarations or
cache-control metadata. They are not general `BeamWeaver.Agent.Middleware`
callbacks.

```elixir
opts =
  BeamWeaver.Anthropic.Middleware.Bash.new()
  |> BeamWeaver.Anthropic.Middleware.Bash.call_opts()
```

{% hint style="warning" %}
**Provider Middleware Catalog**

Python LangChain has separate provider middleware pages for Anthropic, AWS, and
OpenAI. BeamWeaver currently documents provider behavior in the provider guides
and provider modules. AWS/Bedrock-specific prompt caching middleware is not part
of BeamWeaver until there is a first-class AWS provider adapter.
{% endhint %}

## Related Guides

- [Middleware](middleware.md)
- [Custom Middleware](custom_middleware.md)
- [Guardrails](guardrails.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Runtime](runtime.md)
- [Agents](agents.md)
- [Context Engineering](context_engineering.md)
- [Subagents](subagents.md)
- [Async Subagents](async_subagents.md)
- [Tools](tools.md)
- [Short-Term Memory](short_term_memory.md)
- [Structured Output](structured_output.md)
- [Event Streaming](event_streaming.md)
