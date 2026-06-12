# Context Engineering

Context engineering is choosing what information, tools, instructions, and
state the model sees at each point in an agent run. Most agent failures are not
caused by the model being incapable; they happen because the model call did not
receive the right context in the right shape.

In BeamWeaver, context engineering is done with four main surfaces:

| Surface | Controls |
| --- | --- |
| Model context | System prompt, messages, tools, selected model, and response format for one model call. |
| Tool context | What tools can read from state, store, runtime context, and external systems, and what they write back. |
| Lifecycle context | Middleware that runs before, after, or around model and tool calls. |
| Memory context | Short-term state, checkpoints, and long-term stores. |

{% hint style="info" %}
**BeamWeaver Shape**

LangChain's Python examples use `create_agent`, decorators like
`@dynamic_prompt`, Pydantic/dataclasses, and annotation-based `ToolRuntime`
parameters. BeamWeaver uses `use BeamWeaver.Agent` or
`BeamWeaver.Agent.build/1`, explicit Elixir middleware, JSON Schema-shaped
schemas, tagged results, and explicit tool argument injection.
{% endhint %}

## Deep Agents Context Map

Official Deep Agents describes five kinds of context. BeamWeaver keeps the same
concepts but exposes them through the normal agent, middleware, filesystem, and
memory APIs:

| Deep Agents context type | BeamWeaver surface | Scope |
| --- | --- | --- |
| Input context | `system_prompt`, `memory`, `skills`, tool descriptions, and middleware prompt additions | Static per agent or assembled per model call |
| Runtime context | `context: ...`, `context_schema`, `runtime.context`, injected tool context | One invocation or thread; propagated to BeamWeaver subagents |
| Context compression | `BeamWeaver.Agent.Middleware.Filesystem`, `Summarization`, `CompactConversation`, and `OverflowRecovery` | Before model calls, after tool calls, or after context-overflow errors |
| Context isolation | `subagents`, `async_subagents`, graph subgraphs, and compiled agents-as-graphs | Per delegated task or nested graph |
| Long-term memory | `runtime.store`, `BeamWeaver.Memory` adapters, and store-backed filesystem routes | Persistent across threads and conversations |

## Input Context

Input context is the model-facing context assembled at the start of a model call:
the system prompt, memory files, skills, tool metadata, and instructions added
by harness middleware.

### System Prompt

Use `system_prompt` for static role and behavior instructions:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    model: BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6"),
    system_prompt:
      "You are a research assistant. Cite sources and delegate parallel research.",
    tools: []
  )
```

For dynamic prompt context, use middleware instead of a Python
`@dynamic_prompt` decorator:

```elixir
middleware do
  use BeamWeaver.Agent.Middleware.DynamicPrompt,
    prompt: fn request ->
      role = get_in(request.runtime.context || %{}, [:role]) || "reader"
      "You are helpful. The current user's role is #{role}."
    end
end
```

Use dynamic prompt middleware only when the model itself needs to see the
derived context. Tools do not need prompt middleware just to read context; they
can receive `:context`, `:store`, or `%BeamWeaver.Core.ToolRuntime{}` through
explicit injection.

### Memory Files

`memory` adds always-loaded persistent context such as `AGENTS.md` files,
project conventions, and user preferences:

```elixir
BeamWeaver.Agent.build(
  model: "openai:gpt-5.4",
  memory: ["/AGENTS.md", "/preferences.md"]
)
```

Memory files are loaded into the agent's working context when configured. They
do not use progressive disclosure, so keep them short and put detailed,
task-specific workflows in skills.

### Skills

`skills` add progressively disclosed workflows. The agent sees skill metadata at
startup and can load the full skill content when it is relevant:

```elixir
BeamWeaver.Agent.build(
  model: "openai:gpt-5.4",
  skills: ["/skills/research", "/skills/release-notes"]
)
```

Keep skills focused. Broad, overlapping skills make selection harder and can
bloat the model context once loaded.

See [Skills](skills.md) for skill source precedence, store-backed skill
libraries, subagent inheritance, and differences from Deep Agents interpreter
skills.

### Tool Prompts

Tool descriptions and JSON Schemas are context. Built-in harness middleware also
adds tool-specific prompt guidance:

| Capability | Prompt/tool context |
| --- | --- |
| Planning | `BeamWeaver.Agent.Middleware.TodoList` adds TODO guidance and a task-list tool. |
| Filesystem | `BeamWeaver.Agent.Middleware.Filesystem` documents `ls`, `read_file`, `write_file`, `edit_file`, `glob`, `grep`, and `execute` when available. |
| Subagents | `BeamWeaver.Agent.Middleware.Subagents` documents the `task` delegation tool. |
| Human review | `BeamWeaver.Agent.Middleware.HumanInTheLoop` explains interrupted tool calls when `interrupt_on` is configured. |

For user-provided tools, put the "when to use this" guidance in the tool
description and use argument descriptions in the schema:

```elixir
defmodule MyApp.Tools.SearchOrders do
  use BeamWeaver.Tool

  name "search_orders"
  description "Search a user's orders by status. Use when the user asks about order history."

  schema do
    field :user_id, :string, description: "Unique user identifier"
    field :status, :string, description: "Order status: pending, shipped, or delivered"
    field :limit, :integer, required: false, default: 10
  end
end
```

Use `BeamWeaver.Agent.Middleware.ToolSelection`, `tool_descriptions`, or
`exclude_tools` to override descriptions or hide tools for a provider, model,
role, or task stage.

### Complete System Prompt

BeamWeaver does not expose Deep Agents' exact Python prompt assembly list.
The assembled prompt normally contains:

1. Agent `system_prompt`, if provided.
2. Dynamic prompt middleware output, if configured.
3. Built-in capability prompt additions for TODOs, memory, skills, filesystem,
   subagents, compaction, prompt caching, and human review.
4. Tool descriptions and schemas.
5. Custom middleware prompt additions.

The exact ordering follows the agent's middleware pipeline. If ordering matters,
declare middleware explicitly instead of relying on defaults.

## Agent Loop

A typical agent loop has two steps:

1. The model receives messages, a system prompt, available tools, and optional
   response-format instructions.
2. The tool node executes requested tools and returns tool messages or state
   commands.

The loop continues until the model stops requesting tools. Reliable agents
control what happens before, during, and after those steps.

| Context type | What you control | Persistence |
| --- | --- | --- |
| Model context | Instructions, message list, tool list, model choice, response format. | Usually transient for one model call. |
| Tool context | Tool reads and writes from state, store, runtime context, and external systems. | Often persistent through state or store writes. |
| Lifecycle context | Summarization, guardrails, logging, retries, jumps, context editing. | Often persistent when hooks update state. |

## Data Sources

Agents work with three data sources:

| Source | BeamWeaver API | Scope | Examples |
| --- | --- | --- | --- |
| Runtime context | `context: ...`, `context_schema`, `runtime.context` | One invocation or conversation thread | User ID, tenant, permissions, locale, request config. |
| State | Graph channels and agent state | Current thread or run | Messages, uploaded files, auth state, tool results, counters. |
| Store | `BeamWeaver.Memory` adapters through `runtime.store` | Cross-conversation | User preferences, memories, feature flags, historical facts. |

Use [Runtime](runtime.md) for per-run dependency injection, [Short-Term
Memory](short_term_memory.md) for state and checkpoints, and stores for
long-term memory.

## Runtime Context

Runtime context is per-run configuration passed at invocation time. It is not
automatically included in the model prompt; the model sees it only if a tool,
middleware, or graph node reads it and writes it into messages, state, or the
system prompt.

Define expected context with `context_schema`, then pass values with
`context: ...`:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4",
    tools: [MyApp.Tools.FetchUserData],
    context_schema: %{
      user_id: %{type: :string, required: true},
      api_key: %{type: :string, required: true}
    }
  )

BeamWeaver.Agent.invoke(
  agent,
  %{messages: [BeamWeaver.Core.Message.user("Get my recent activity.")]},
  context: %{user_id: "user-123", api_key: "sk-..."}
)
```

Inside tools, read runtime context through explicit injection:

```elixir
BeamWeaver.Core.Tool.from_function!(
  name: "fetch_user_data",
  description: "Fetch data for the current user.",
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
    {:ok, "Data for #{user_id}: #{query}"}
  end
)
```

Runtime context propagates to BeamWeaver subagents created by
`BeamWeaver.Agent.Middleware.Subagents` and `AsyncSubagents`. For per-subagent
specialization, namespace keys in the context map or configure each
`BeamWeaver.Agent.Subagent.Spec` with its own tools, prompt, skills, and
permissions.

## Model Context

Model context is what the model sees for a particular call. Most model-context
changes should be transient: they shape one request without rewriting saved
state.

### System Prompt

Use middleware to compute the system prompt from state, store, or runtime
context.

```elixir
defmodule MyApp.StateAwarePrompt do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest

  def name(_middleware), do: :state_aware_prompt

  def wrap_model_call(%ModelRequest{} = request, handler) do
    message_count = length(request.messages)

    prompt =
      if message_count > 10 do
        "You are a helpful assistant. This is a long conversation; be concise."
      else
        "You are a helpful assistant."
      end

    request
    |> ModelRequest.override(system_prompt: prompt)
    |> handler.()
  end
end
```

For simple prompt computation, use the prebuilt dynamic prompt middleware:

```elixir
middleware do
  use BeamWeaver.Agent.Middleware.DynamicPrompt,
    prompt: fn request ->
      user_name = get_in(request.runtime.context || %{}, [:user_name]) || "there"
      "You are helpful. Address the user as #{user_name}."
    end
end
```

Store-aware prompts read long-term memory through `runtime.store`:

```elixir
defmodule MyApp.PreferencePrompt do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Memory

  def name(_middleware), do: :preference_prompt

  def wrap_model_call(%ModelRequest{} = request, handler) do
    user_id = get_in(request.runtime.context || %{}, [:user_id])
    store = request.runtime.store

    style =
      case Memory.get(store, ["preferences"], user_id) do
        {:ok, %{value: %{"communication_style" => value}}} -> value
        _other -> "balanced"
      end

    request
    |> ModelRequest.override(system_prompt: "You are helpful. User prefers #{style} responses.")
    |> handler.()
  end
end
```

### Messages

Use `wrap_model_call` to transiently modify the message list for one model call.
This is useful for adding file summaries, retrieved snippets, compliance rules,
or user-specific writing style without saving those additions to state.

```elixir
defmodule MyApp.FileContext do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Message

  def name(_middleware), do: :file_context

  def wrap_model_call(%ModelRequest{} = request, handler) do
    files = Map.get(request.state || %{}, :uploaded_files, [])

    messages =
      if files == [] do
        request.messages
      else
        descriptions =
          Enum.map_join(files, "\n", fn file ->
            "- #{file.name}: #{file.summary}"
          end)

        request.messages ++
          [Message.user("Files available in this conversation:\n#{descriptions}")]
      end

    request
    |> ModelRequest.override(messages: messages)
    |> handler.()
  end
end
```

{% hint style="info" %}
**Transient And Persistent Messages**

`ModelRequest.override(messages: ...)` changes only the current model call. To
persist message changes, update state from a lifecycle hook or return
`%BeamWeaver.Graph.Command{update: %{messages: [...]}}` from a tool or graph
node. Wrap-model middleware can also return
`%BeamWeaver.Agent.ExtendedModelResponse{}` with a command.
{% endhint %}

### Tools

Tool definitions are context. Names, descriptions, argument descriptions, and
schemas all shape the model's decision about when and how to call a tool.

```elixir
defmodule MyApp.Tools.SearchOrders do
  use BeamWeaver.Tool

  name "search_orders"
  description "Search a user's orders by status. Use when the user asks about order history or order status."

  schema do
    field :user_id, :string, description: "Unique user identifier"
    field :status, :string, description: "Order status: pending, shipped, or delivered"
    field :limit, :integer, required: false, default: 10
  end

  @impl true
  def invoke(_tool, input, _opts) do
    {:ok, "Found #{Map.get(input, :limit, 10)} #{input.status} orders for #{input.user_id}."}
  end
end
```

Too many tools can overload model context. Filter or add tools dynamically with
`BeamWeaver.Agent.Middleware.ToolSelection` or custom `wrap_model_call`
middleware.

```elixir
defmodule MyApp.PermissionTools do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Tool

  def name(_middleware), do: :permission_tools

  def wrap_model_call(%ModelRequest{} = request, handler) do
    role = get_in(request.runtime.context || %{}, [:user_role]) || "viewer"

    tools =
      case role do
        "admin" -> request.tools
        "editor" -> Enum.reject(request.tools, &(Tool.name(&1) == "delete_data"))
        _viewer ->
          Enum.filter(request.tools, &(Tool.name(&1) |> String.starts_with?("read_")))
      end

    request
    |> ModelRequest.override(tools: tools)
    |> handler.()
  end
end
```

{% hint style="warning" %}
**Runtime Tool Discovery**

LangChain documents dynamic tool registration from sources such as MCP servers.
BeamWeaver supports dynamic tool lists through middleware and runtime-built
agents, but it does not currently ship a first-class MCP runtime discovery page
or hosted tool registry. Convert discovered tools into BeamWeaver tool values
before passing them to the agent.
{% endhint %}

### Model

Use `wrap_model_call` to pick a model based on state, store, or runtime
context.

```elixir
defmodule MyApp.DynamicModel do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest

  def name(_middleware), do: :dynamic_model

  def wrap_model_call(%ModelRequest{} = request, handler) do
    tier = get_in(request.runtime.context || %{}, [:cost_tier]) || "standard"

    model =
      cond do
        length(request.messages) > 20 ->
          BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6")

        tier == "budget" ->
          BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")

        true ->
          BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
      end

    request
    |> ModelRequest.override(model: model)
    |> handler.()
  end
end
```

### Response Format

Structured output is model context because it changes the shape the model must
produce.

```elixir
defmodule MyApp.DynamicResponseFormat do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.StructuredOutput

  @simple_schema %{
    "title" => "simple_response",
    "type" => "object",
    "required" => ["answer"],
    "properties" => %{"answer" => %{"type" => "string"}}
  }

  @detailed_schema %{
    "title" => "detailed_response",
    "type" => "object",
    "required" => ["answer", "confidence"],
    "properties" => %{
      "answer" => %{"type" => "string"},
      "confidence" => %{"type" => "number"}
    }
  }

  def name(_middleware), do: :dynamic_response_format

  def wrap_model_call(%ModelRequest{} = request, handler) do
    schema =
      if length(request.messages) < 3 do
        StructuredOutput.tool(@simple_schema)
      else
        StructuredOutput.tool(@detailed_schema)
      end

    request
    |> ModelRequest.override(response_format: schema)
    |> handler.()
  end
end
```

For static agent structured output, use `response_schema/2` in the agent module.
See [Structured Output](structured_output.md) for provider and tool strategies.

{% hint style="warning" %}
**No Pydantic Or TypedDict Schemas**

Python examples use Pydantic models and `TypedDict`. BeamWeaver uses
`BeamWeaver.Schema` for stable module contracts and JSON Schema-shaped maps for
dynamic/wire-level contracts. Elixir structs and typespecs are not enough to
describe provider-facing schema
validation.
{% endhint %}

## Tool Context

Tools are where agents interact with databases, APIs, files, and other external
systems. Tools can read context and write new context.

### Reads

Use injected arguments or `%BeamWeaver.Core.ToolRuntime{}` to read state, store,
runtime context, execution metadata, or the current tool call ID.

```elixir
alias BeamWeaver.Core.Tool

check_authentication =
  Tool.from_function!(
    name: "check_authentication",
    description: "Check whether the current user is authenticated.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"state" => %{"type" => "object"}},
      "required" => ["state"]
    },
    injected: [state: :state],
    handler: fn input, _opts ->
      state = input[:state] || input["state"] || %{}

      if Map.get(state, :authenticated, Map.get(state, "authenticated", false)) do
        "User is authenticated."
      else
        "User is not authenticated."
      end
    end
  )
```

Read from runtime context and store together:

```elixir
get_preference =
  Tool.from_function!(
    name: "get_preference",
    description: "Get a user preference from long-term memory.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "preference_key" => %{"type" => "string"},
        "context" => %{"type" => "object"},
        "store" => %{"type" => "object"}
      },
      "required" => ["preference_key", "context", "store"]
    },
    injected: [context: :context, store: :store],
    handler: fn input, _opts ->
      key = input["preference_key"] || input[:preference_key]
      context = input[:context] || input["context"] || %{}
      user_id = context[:user_id] || context["user_id"]

      case BeamWeaver.Memory.get(input[:store] || input["store"], ["preferences"], user_id) do
        {:ok, %{value: prefs}} -> Map.get(prefs, key, "No preference set.")
        _other -> "No preferences found."
      end
    end
  )
```

### Writes

Return `%BeamWeaver.Graph.Command{}` when a tool should update state. Include a
tool message in the update when the model needs an observation.

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Graph.Command

authenticate_user =
  Tool.from_function!(
    name: "authenticate_user",
    description: "Authenticate a user and update session state.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "password" => %{"type" => "string"},
        "tool_call_id" => %{"type" => "string"}
      },
      "required" => ["password", "tool_call_id"]
    },
    injected: [tool_call_id: :tool_call_id],
    handler: fn input, _opts ->
      authenticated? = (input["password"] || input[:password]) == "correct"
      call_id = input[:tool_call_id] || input["tool_call_id"]

      %Command{
        update: %{
          authenticated: authenticated?,
          messages: [
            Message.tool("Authentication updated.", tool_call_id: call_id)
          ]
        }
      }
    end
  )
```

Write to long-term memory through `BeamWeaver.Memory`:

```elixir
save_preference =
  Tool.from_function!(
    name: "save_preference",
    description: "Save a user preference.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "preference_key" => %{"type" => "string"},
        "preference_value" => %{"type" => "string"},
        "context" => %{"type" => "object"},
        "store" => %{"type" => "object"}
      },
      "required" => ["preference_key", "preference_value", "context", "store"]
    },
    injected: [context: :context, store: :store],
    handler: fn input, _opts ->
      context = input[:context] || input["context"] || %{}
      user_id = context[:user_id] || context["user_id"]
      key = input["preference_key"] || input[:preference_key]
      value = input["preference_value"] || input[:preference_value]
      store = input[:store] || input["store"]

      :ok = BeamWeaver.Memory.put(store, ["preferences"], user_id, %{key => value})

      "Saved preference."
    end
  )
```

{% hint style="info" %}
**State And Store Are Different**

State is short-term thread data and is checkpointed with the graph. Store is
long-term memory and can be shared across conversations. Use state for the
current task and store for durable user or application memory.
{% endhint %}

## Lifecycle Context

Lifecycle context is everything that happens between model and tool calls:
summarization, context editing, guardrails, logging, retries, fallbacks, and
early exits.

Prebuilt middleware covers common lifecycle policies:

```elixir
middleware do
  use BeamWeaver.Agent.Middleware.Summarization,
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini"),
    trigger: {:tokens, 4_000},
    keep: {:messages, 20}

  use BeamWeaver.Agent.Middleware.PII,
    detectors: [:email, :credit_card],
    strategy: :redact,
    apply_to_input: true

  use BeamWeaver.Agent.Middleware.ModelCallLimit,
    run_limit: 5,
    thread_limit: 20
end
```

Custom middleware can update state or jump in the lifecycle:

```elixir
defmodule MyApp.BlockUnauthenticatedWrites do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  def name(_middleware), do: :block_unauthenticated_writes

  def can_jump_to(_middleware, :before_model), do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  def before_model(state, _runtime) do
    authenticated? = Map.get(state, :authenticated, false)

    if authenticated? do
      nil
    else
      %{
        messages: [Message.assistant("Please authenticate before modifying data.")],
        jump_to: :end
      }
    end
  end
end
```

Use [Guardrails](guardrails.md) for safety policies,
[Prebuilt Middleware](prebuilt_middleware.md) for common lifecycle middleware,
and [Custom Middleware](custom_middleware.md) for writing your own hooks.

## Context Compression

Long-running agents accumulate large tool results and message histories.
BeamWeaver provides three compression mechanisms that map to the official Deep
Agents page: filesystem offloading, automatic summarization, and explicit
conversation compaction.

### Offloading

`BeamWeaver.Agent.Middleware.Filesystem` offloads oversized context into the
agent filesystem:

- Tool results above the middleware's token threshold are saved under
  `/large_tool_results/<tool_call_id>` and replaced with a path, pagination
  instructions, and a head/tail preview.
- Oversized user messages can be saved under `/conversation_history/...` and
  replaced with a pointer and preview before the next model call.
- Offloaded content can be recovered with `read_file` pagination or searched
  with `grep`.

```elixir
BeamWeaver.Agent.build(
  model: "openai:gpt-5.4",
  filesystem: BeamWeaver.Filesystem.State.new(),
  overflow_recovery: true
)
```

Defaults are close to the Deep Agents behavior but not identical: BeamWeaver
offloads large tool results around a 20,000-token estimate and oversized human
messages around a 50,000-token estimate. Tune
`:tool_token_limit_before_evict` and `:human_message_token_limit_before_evict`
on `BeamWeaver.Agent.Middleware.Filesystem` when a different policy is needed.

### Summarization

`BeamWeaver.Agent.Middleware.Summarization` summarizes older messages before a
model call when configured thresholds are reached:

```elixir
middleware do
  use BeamWeaver.Agent.Middleware.Summarization,
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini"),
    trigger: {:fraction, 0.85},
    keep: {:fraction, 0.10}
end
```

Use token or message thresholds when the model profile does not include
`max_input_tokens`. Fractional thresholds require profile data.

### Manual Compaction Tool

`compact_conversation: true` adds a `compact_conversation` tool. The model can
use it between tasks to replace older messages with a summary while preserving
recent context:

```elixir
BeamWeaver.Agent.build(
  model: "openai:gpt-5.4",
  filesystem: BeamWeaver.Filesystem.State.new(),
  compact_conversation: true
)
```

Manual compaction does not disable automatic summarization or overflow recovery;
combine them when long-running agents need both proactive and reactive context
management.

### Overflow Recovery

`overflow_recovery: true` catches provider context-overflow errors, clips the
large trailing tool-message batch, offloads recoverable content to the
filesystem, and retries the model call:

```elixir
BeamWeaver.Agent.build(
  model: "anthropic:claude-sonnet-4-6",
  filesystem: BeamWeaver.Filesystem.State.new(),
  overflow_recovery: [keep: {:messages, 8}]
)
```

This is reactive recovery, not a guarantee that every possible provider context
error can be salvaged. Keep tool outputs concise and use subagents for heavy
work.

## Context Isolation With Subagents

Subagents keep heavy work out of the main agent's message context. The parent
agent sees a single final report instead of every intermediate search, file
read, or tool result from the delegated task.

```elixir
alias BeamWeaver.Agent.Subagent

BeamWeaver.Agent.build(
  model: "openai:gpt-5.4",
  tools: [MyApp.Tools.WebSearch],
  subagents: [
    Subagent.Spec.new(
      name: "researcher",
      description: "Conduct multi-step research and return concise sourced notes.",
      system_prompt: """
      Return only the essential summary, under 500 words.
      Do not include raw search results or long tool outputs.
      """
    )
  ]
)
```

Use subagents for multi-step or output-heavy tasks, give each subagent focused
tools and instructions. When a child needs its own file workspace, compose
filesystem middleware for that subagent and have it write large artifacts to the
filesystem while returning concise summaries or paths.

See [Subagents](subagents.md) for the synchronous `task` tool and
[Async Subagents](async_subagents.md) for background task descriptors,
lifecycle, and `:async_tasks` state.

Use [Filesystem Permissions](permissions.md) when path-based rules should shape
what the main agent or a synchronous subagent can read or write through the
built-in filesystem tools.

For graph-level isolation, use compiled subgraphs or agents-as-graphs instead of
the `task` tool. Subgraphs are statically discoverable and can participate in
graph persistence, streaming, and state inspection.

## Long-Term Memory

Long-term memory lives in `runtime.store` and `BeamWeaver.Memory` adapters. For
Deep Agents-style filesystem memory, route a virtual path prefix to a store
backed filesystem:

```elixir
store = BeamWeaver.Memory.ETS.new()

filesystem =
  BeamWeaver.Filesystem.Composite.new(
    default: BeamWeaver.Filesystem.State.new(),
    routes: %{
      "/memories/" =>
        BeamWeaver.Filesystem.Store.new(store: store, namespace: ["memories"])
    }
  )

BeamWeaver.Agent.build(
  model: "openai:gpt-5.4",
  store: store,
  filesystem: filesystem,
  system_prompt: """
  When users share durable preferences, save them under /memories/preferences.txt.
  Read /memories/ when you need remembered user preferences.
  """
)
```

You do not need to pre-populate memory files. Give the agent clear instructions
for what belongs under `/memories/`, and let filesystem tools create or edit
files as useful information appears.

For direct key/value or semantic memory, use [Long-Term Memory](long_term_memory.md)
instead of going through a virtual file path.

## Best Practices

- Start with static prompts and a small tool set.
- Add dynamic context only after you can explain why the static version fails.
- Keep transient model context separate from persistent state updates.
- Prefer runtime `context` for request data and `store` for cross-conversation
  memory.
- Use tool descriptions and argument descriptions as model-facing instructions.
- Filter tools aggressively when permissions, task stage, or feature flags make
  tools irrelevant.
- Use subagents for multi-step, output-heavy work that would clutter the parent
  agent's message history.
- Store large artifacts in the filesystem and refer to paths instead of copying
  raw data back into the prompt.
- Document the structure of `/memories/` or other persistent namespaces in the
  system prompt or memory files.
- Test context logic independently with fake or replay models.
- Observe context decisions with [Event Streaming](event_streaming.md) and
  [Tracing](tracing.md).

## Related Guides

- [Agents](agents.md)
- [Composed Agent Capabilities](agent_harness.md)
- [Filesystem](filesystem.md)
- [Filesystem Permissions](permissions.md)
- [Subagents](subagents.md)
- [Async Subagents](async_subagents.md)
- [Runtime](runtime.md)
- [Tools](tools.md)
- [Middleware](middleware.md)
- [Custom Middleware](custom_middleware.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Guardrails](guardrails.md)
- [Short-Term Memory](short_term_memory.md)
- [Long-Term Memory](long_term_memory.md)
- [Memory](memory.md)
- [Subgraphs](subgraphs.md)
- [Structured Output](structured_output.md)
- [Event Streaming](event_streaming.md)
