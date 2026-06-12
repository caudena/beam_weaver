# Custom Middleware

Custom middleware lets you intercept agent execution at well-defined lifecycle
points. Use it when the built-in middleware does not cover a policy you need:
logging, validation, custom state updates, dynamic model selection, tool
filtering, audit trails, caching, or domain-specific guardrails.

Middleware is compiled into the agent graph. It is not a separate callback
runtime, and it travels with the compiled agent when the agent is embedded as a
subgraph.

{% hint style="info" %}
**Elixir Modules Instead Of Python Decorators**

LangChain's Python docs show decorator-based middleware such as
`@before_model` and class-based `AgentMiddleware`. BeamWeaver does not expose
decorators. A custom middleware is an Elixir module or struct that implements
optional callbacks from `BeamWeaver.Agent.Middleware`.
{% endhint %}

## Hook Types

BeamWeaver supports the same two hook styles as the Python execution model:

| Style | Hooks | Use for |
| --- | --- | --- |
| Node-style hooks | `before_agent`, `before_model`, `after_model`, `after_agent` | Sequential state inspection, logging, validation, routing, and state updates. |
| Wrap-style hooks | `wrap_model_call`, `wrap_tool_call` | Around-call control flow such as retry, fallback, request rewriting, response rewriting, caching, or short-circuiting. |

Node-style hooks return state updates. Wrap-style hooks receive an immutable
request and a handler function. A wrapper can call the handler zero times, once,
or multiple times.

## Node-Style Hooks

Use node-style hooks when the middleware should run at a fixed point in the
agent loop.

| Hook | Runs |
| --- | --- |
| `before_agent/2` or `before_agent/3` | Once, before the agent starts. |
| `before_model/2` or `before_model/3` | Before each model call. |
| `after_model/2` or `after_model/3` | After each model response. |
| `after_agent/2` or `after_agent/3` | Once, after the agent is ready to finish. |

Use the two-argument form for stateless module middleware:

```elixir
defmodule MyApp.LogBeforeModel do
  @behaviour BeamWeaver.Agent.Middleware

  require Logger

  def name(_middleware), do: :log_before_model

  def before_model(state, runtime) do
    Logger.info("node=#{runtime.node} messages=#{length(Map.get(state, :messages, []))}")
    nil
  end
end
```

Use the three-argument form when the middleware stores configuration in a
struct:

```elixir
defmodule MyApp.MessageLimitMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  defstruct max_messages: 50

  def new(opts \\ []) do
    %__MODULE__{max_messages: Keyword.get(opts, :max_messages, 50)}
  end

  def name(_middleware), do: :message_limit

  def can_jump_to(_middleware, :before_model), do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  def before_model(%__MODULE__{max_messages: max}, state, _runtime) do
    if length(Map.get(state, :messages, [])) >= max do
      %{
        messages: [Message.assistant("Conversation limit reached.")],
        jump_to: :end
      }
    else
      nil
    end
  end

  def after_model(_middleware, state, _runtime) do
    state
    |> Map.get(:messages, [])
    |> List.last()
    |> case do
      nil -> :ok
      message -> IO.inspect(Message.text(message), label: "Model returned")
    end

    nil
  end
end
```

Attach it to a module-defined agent:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")

  middleware do
    use MyApp.MessageLimitMiddleware, max_messages: 50
  end
end
```

## Wrap-Style Hooks

Use wrappers when the middleware needs control over an individual model or tool
call.

### Model Wrappers

`wrap_model_call` receives a `BeamWeaver.Agent.ModelRequest` and a handler. Call
the handler with the original request or with a request produced by
`BeamWeaver.Agent.ModelRequest.override/2`.

```elixir
defmodule MyApp.RetryModelMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  defstruct max_attempts: 3

  def new(opts \\ []) do
    %__MODULE__{max_attempts: Keyword.get(opts, :max_attempts, 3)}
  end

  def name(_middleware), do: :retry_model

  def wrap_model_call(%__MODULE__{max_attempts: max}, request, handler) do
    retry(request, handler, max, 1)
  end

  defp retry(request, handler, max, attempt) do
    case handler.(request) do
      {:error, error} when attempt < max ->
        IO.inspect(error, label: "Retry #{attempt}/#{max}")
        retry(request, handler, max, attempt + 1)

      result ->
        result
    end
  end
end
```

For production retry behavior, prefer
`BeamWeaver.Agent.Middleware.ModelRetry`, which uses `BeamWeaver.RetryPolicy`
and emits telemetry.

### Tool Wrappers

`wrap_tool_call` receives a `BeamWeaver.Agent.ToolCallRequest` and a handler.
Use it for tool monitoring, tool-specific policy checks, custom retries, or
tool output rewriting.

```elixir
defmodule MyApp.ToolMonitoringMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  require Logger

  def name(_middleware), do: :tool_monitoring

  def wrap_tool_call(request, handler) do
    tool_name = tool_call_value(request.tool_call, :name)
    args = tool_call_value(request.tool_call, :args) || %{}

    Logger.info("executing tool=#{tool_name} args=#{inspect(args)}")

    case handler.(request) do
      {:error, error} = result ->
        Logger.warning("tool=#{tool_name} failed type=#{inspect(error.type)}")
        result

      result ->
        Logger.info("tool=#{tool_name} completed")
        result
    end
  end

  defp tool_call_value(call, key) do
    Map.get(call, key) || Map.get(call, Atom.to_string(key))
  end
end
```

{% hint style="warning" %}
**Tool Commands Must Return A Matching Tool Message**

Python tool middleware can return a `Command` from `wrap_tool_call`. BeamWeaver
also supports `%BeamWeaver.Graph.Command{}`, but a tool command that updates
messages must include exactly one matching tool message for the active
`tool_call_id`, unless it is an explicit parent-graph command or a remove-all
messages command.
{% endhint %}

## State Updates

Node-style hooks return a map or `%BeamWeaver.Graph.Command{}`. The graph
merges updates through the state schema's channels.

```elixir
defmodule MyApp.CountModelCalls do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.LastValue

  def name(_middleware), do: :count_model_calls

  def state_schema(_middleware) do
    %{model_call_count: Graph.channel(LastValue)}
  end

  def after_model(state, _runtime) do
    %{model_call_count: Map.get(state, :model_call_count, 0) + 1}
  end
end
```

Model wrappers can update state by returning
`%BeamWeaver.Agent.ExtendedModelResponse{}` with a command:

```elixir
defmodule MyApp.UsageTrackingMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.LastValue
  alias BeamWeaver.Graph.Command

  def name(_middleware), do: :usage_tracking

  def state_schema(_middleware) do
    %{last_model_call_tokens: Graph.channel(LastValue)}
  end

  def wrap_model_call(request, handler) do
    with {:ok, %ModelResponse{} = response} <- handler.(request) do
      tokens =
        response.usage
        |> case do
          nil -> 0
          usage -> usage.total_tokens || 0
        end

      %ExtendedModelResponse{
        model_response: response,
        command: %Command{update: %{last_model_call_tokens: tokens}}
      }
    end
  end
end
```

When several model wrappers return extended responses, BeamWeaver composes their
commands through graph reducers. Message updates are additive. For last-value
fields, inner updates are applied first and outer middleware can overwrite
conflicting keys.

{% hint style="info" %}
**Command Composition Matches Graph Semantics**

LangChain documents `ExtendedModelResponse(command=Command(...))`. BeamWeaver
supports the same idea with `%BeamWeaver.Agent.ExtendedModelResponse{}` and
`%BeamWeaver.Graph.Command{}`. The difference is shape: commands are Elixir
structs and updates are reduced by BeamWeaver graph channels.
{% endhint %}

## Custom State And Context

Middleware can declare state fields and required runtime context. This keeps
the schema close to the middleware that owns it.

```elixir
defmodule MyApp.UserPreferenceMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Schema
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.LastValue

  def name(_middleware), do: :user_preferences

  def state_schema(_middleware) do
    %{
      preferences: Graph.channel(LastValue)
    }
  end

  def context_schema(_middleware) do
    %{
      user_id: Schema.field(:user_id, :string, required: true)
    }
  end

  def before_model(state, runtime) do
    preferences = Map.get(state, :preferences, %{})
    %{preferences: Map.put(preferences, :user_id, runtime.context.user_id)}
  end
end
```

You can also use private graph channels for middleware-only state:

```elixir
def state_schema(_middleware) do
  %{
    private_audit_trace:
      BeamWeaver.Graph.private_channel(BeamWeaver.Graph.Channels.LastValue)
  }
end
```

Private state is available to later hooks during execution, but is hidden from
the final public state.

{% hint style="info" %}
**TypedDict And Annotated Reducers Are Python-Specific**

Python examples use `TypedDict`, dataclasses, or `Annotated` reducers for
middleware state. BeamWeaver uses graph channels such as
`BeamWeaver.Graph.Channels.LastValue`, message reducers, and private channels.
{% endhint %}

## Execution Order

Middleware runs in the order passed to the agent:

```elixir
middleware do
  use MyApp.One
  use MyApp.Two
  use MyApp.Three
end
```

Order rules:

- `before_agent` and `before_model` run first-to-last.
- `wrap_model_call` and `wrap_tool_call` nest first-to-last. The first
  middleware wraps all later middleware and the final model or tool call.
- `after_model` and `after_agent` run last-to-first.
- `before_agent` and `after_agent` run once per invocation.
- `before_model`, `wrap_model_call`, and `after_model` run once per model
  iteration.
- `wrap_tool_call` runs once per tool execution.

If a wrapper calls the handler multiple times, only the returned attempt's
extended command updates are applied.

## Agent Jumps

Node-style hooks can route the agent to another lifecycle point. Return
`%{jump_to: target}` or `{:jump, target, update}` and declare the allowed target
with `can_jump_to/2`.

Supported jump targets are:

| Target | Meaning |
| --- | --- |
| `:end` | Finish the agent and continue through `after_agent` hooks. |
| `:tools` | Jump to tool execution. |
| `:model` | Jump back to the model path. |

```elixir
defmodule MyApp.BlockedContentMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  def name(_middleware), do: :blocked_content

  def can_jump_to(_middleware, :after_model), do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  def after_model(state, _runtime) do
    last_message = state |> Map.get(:messages, []) |> List.last()

    if last_message && String.contains?(Message.text(last_message), "BLOCKED") do
      %{
        messages: [Message.assistant("I cannot respond to that request.")],
        jump_to: :end
      }
    else
      nil
    end
  end
end
```

{% hint style="warning" %}
**No `hook_config` Decorator**

Python uses `@hook_config(can_jump_to=[...])`. BeamWeaver uses a normal
callback: `can_jump_to(middleware, hook)`. This makes the allowed edges visible
when BeamWeaver compiles the agent graph.
{% endhint %}

## Common Patterns

### Dynamic Prompt

Use `BeamWeaver.Agent.Middleware.DynamicPrompt` for most dynamic prompt cases.
For fully custom behavior, override the model request.

```elixir
defmodule MyApp.ContextPromptMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Message

  def name(_middleware), do: :context_prompt

  def wrap_model_call(request, handler) do
    existing =
      case request.system_message do
        nil -> ""
        %Message{} = message -> Message.text(message)
      end

    user_name = get_in(request.runtime.context || %{}, [:user_name]) || "the user"

    prompt =
      [existing, "Address the user as #{user_name}."]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    request
    |> ModelRequest.override(system_prompt: prompt)
    |> handler.()
  end
end
```

### Dynamic Model Selection

Use `wrap_model_call` to choose a model at runtime.

```elixir
defmodule MyApp.DynamicModelMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest

  def name(_middleware), do: :dynamic_model

  def wrap_model_call(request, handler) do
    model =
      if length(request.messages) > 10 do
        BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6")
      else
        BeamWeaver.Models.init_chat_model!("anthropic:claude-haiku-4-5")
      end

    request
    |> ModelRequest.override(model: model)
    |> handler.()
  end
end
```

### Dynamic Tool Selection

Use `BeamWeaver.Agent.Middleware.ToolSelection` when you only need allow, deny,
or model-selected tools. Use custom middleware when selection depends on
application-specific context.

```elixir
defmodule MyApp.PermissionToolSelector do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest

  def name(_middleware), do: :permission_tool_selector

  def wrap_model_call(request, handler) do
    allowed_tools =
      if get_in(request.runtime.context || %{}, [:admin?]) do
        request.tools
      else
        Enum.reject(request.tools, &(BeamWeaver.Core.Tool.name(&1) == "admin_delete"))
      end

    request
    |> ModelRequest.override(tools: allowed_tools)
    |> handler.()
  end
end
```

### Tool Call Monitoring

Use `wrap_tool_call` for audit logging around each tool.

```elixir
defmodule MyApp.AuditTools do
  @behaviour BeamWeaver.Agent.Middleware

  def name(_middleware), do: :audit_tools

  def wrap_tool_call(request, handler) do
    started_at = System.monotonic_time()
    result = handler.(request)
    duration = System.monotonic_time() - started_at

    :telemetry.execute(
      [:my_app, :agent, :tool_call],
      %{duration: duration},
      %{tool: tool_name(request)}
    )

    result
  end

  defp tool_name(request) do
    Map.get(request.tool_call, :name) || Map.get(request.tool_call, "name")
  end
end
```

### Prompt Caching With Anthropic

Anthropic prompt caching is provider-specific in BeamWeaver. The helper modules
under `BeamWeaver.Anthropic.Middleware` produce Anthropic call options; they are
not general `BeamWeaver.Agent.Middleware` callbacks.

Use model options or a custom wrapper to add provider call options:

```elixir
defmodule MyApp.AnthropicPromptCacheMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Anthropic.Middleware.PromptCaching

  def name(_middleware), do: :anthropic_prompt_cache

  def wrap_model_call(request, handler) do
    cache_opts =
      PromptCaching.new()
      |> PromptCaching.call_opts()

    request
    |> ModelRequest.override(model_opts: Keyword.merge(request.model_opts, cache_opts))
    |> handler.()
  end
end
```

{% hint style="warning" %}
**Provider-Specific Middleware Scope**

Python's custom middleware page shows provider content blocks and links to
provider middleware integrations. BeamWeaver keeps provider-specific behavior
near provider modules and model options. Use the [Anthropic](partners/anthropic.md) and
[OpenAI](partners/openai.md) guides for supported provider behavior.
{% endhint %}

## Async Hooks

BeamWeaver does not define separate `abefore_model`, `aafter_model`, or async
wrapper callbacks. `BeamWeaver.Agent.async_invoke/3` runs the whole agent
invocation asynchronously. If a custom middleware hook needs concurrent work,
start supervised tasks explicitly and return normal hook values.

{% hint style="info" %}
**Async API Difference**

Python class-based middleware can define sync and async hook implementations.
BeamWeaver uses one callback shape at the graph boundary and relies on OTP
tasks, supervision, and the agent async facade for concurrency.
{% endhint %}

## Best Practices

- Keep each middleware focused on one policy.
- Prefer prebuilt middleware for retries, call limits, summarization, PII, HITL,
  structured-output retry feedback, guardrails, and tool selection.
- Declare middleware-owned state with `state_schema/1`.
- Declare required runtime data with `context_schema/1`.
- Use `ModelRequest.override/2` and `ToolCallRequest.override/2` instead of
  mutating request structs in place.
- Return tagged errors or tool messages instead of raising for expected policy
  failures.
- Be explicit about `can_jump_to/2` when a hook can route execution.
- Unit test middleware modules directly, then test them through an agent.

## Related Guides

- [Middleware](middleware.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Guardrails](guardrails.md)
- [Runtime](runtime.md)
- [Agents](agents.md)
- [Context Engineering](context_engineering.md)
- [Tools](tools.md)
- [Short-Term Memory](short_term_memory.md)
- [Structured Output](structured_output.md)
- [Event Streaming](event_streaming.md)
