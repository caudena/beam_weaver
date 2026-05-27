# Runtime

Runtime is the execution-time environment available during one agent or graph
run. Use it to pass request-specific dependencies into tools, middleware, and
graph nodes without hardcoding globals.

Common runtime data includes:

| Runtime data | Use for |
| --- | --- |
| `context` | Per-run values such as user ID, tenant, permissions, locale, feature flags, or request configuration. |
| `store` | Long-term memory shared across runs or threads. |
| `stream_writer` | Custom application events emitted during Event Streaming. |
| `execution` | Current graph, node, step, task, thread, checkpoint, and run metadata. |
| `server_info` | Optional deployment/auth metadata supplied by your own service boundary. |
| `config` | Graph config, including checkpoint `configurable` values such as `thread_id`. |

{% hint style="info" %}
**Dependency Injection**

Runtime context is BeamWeaver's dependency injection path for tools and
middleware. Pass per-request data through `context: ...` at invocation time
instead of storing it in module attributes, process globals, or application
configuration.
{% endhint %}

## Agent Context

Declare a context schema on a module-defined agent when the run requires
specific context fields:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  tools [MyApp.FetchPreferencesTool]

  context_schema do
    field :user_id, :string, required: true
    field :user_name, :string
  end
end
```

Pass context when invoking the agent:

```elixir
alias BeamWeaver.Core.Message

MyApp.SupportAgent.invoke(
  %{messages: [Message.user("What email style should I use?")]},
  context: %{user_id: "user-123", user_name: "John Smith"}
)
```

Runtime-built agents use the same option:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    name: "support_agent",
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
    tools: [MyApp.FetchPreferencesTool],
    context_schema: %{
      user_id: %{type: :string, required: true}
    }
  )

BeamWeaver.Agent.invoke(
  agent,
  %{messages: [Message.user("What's my account status?")]},
  context: %{user_id: "user-123"}
)
```

{% hint style="warning" %}
**No Python Context Classes**

LangChain's Python examples use dataclasses or `Runtime[Context]`.
BeamWeaver uses explicit context maps plus optional schema validation through
`context_schema`. Elixir structs and typespecs are not inspected as runtime
validation schemas.
{% endhint %}

## Inside Tools

Tools access runtime data through explicit injected arguments. This keeps the
model-visible schema clean while still giving the handler access to context,
store, config, checkpointer, state, or a tool runtime struct.

```elixir
alias BeamWeaver.Core.Tool

fetch_preferences =
  Tool.from_function!(
    name: "fetch_email_preferences",
    description: "Fetch email preferences for the current user.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "context" => %{"type" => "object"},
        "store" => %{"type" => "object"}
      },
      "required" => ["context", "store"]
    },
    injected: [context: :context, store: :store],
    handler: fn input, _opts ->
      context = input[:context] || input["context"] || %{}
      store = input[:store] || input["store"]
      user_id = context[:user_id] || context["user_id"]

      case BeamWeaver.Memory.get(store, ["users"], user_id) do
        {:ok, %{value: %{"preferences" => preferences}}} ->
          preferences

        _other ->
          "The user prefers brief and polite email."
      end
    end
  )
```

Use `%BeamWeaver.Core.ToolRuntime{}` when a tool needs several runtime fields
or needs to emit streamed progress:

```elixir
streaming_tool =
  Tool.from_function!(
    name: "fetch_records",
    description: "Fetch records and stream progress.",
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

      BeamWeaver.Core.ToolRuntime.emit_output_delta(runtime, %{phase: :started})
      BeamWeaver.Core.ToolRuntime.emit_output_delta(runtime, %{phase: :finished})

      "Fetched records for #{input["query"] || input[:query]}"
    end
  )
```

{% hint style="info" %}
**Explicit ToolRuntime Injection**

Python hides `ToolRuntime` parameters by inspecting function annotations.
BeamWeaver does not use annotation magic. Add `injected: [tool_runtime:
:tool_runtime]` or inject the specific fields your handler needs.
{% endhint %}

## Inside Middleware

Node-style middleware hooks receive `%BeamWeaver.Graph.Runtime{}` as the second
or third argument:

```elixir
defmodule MyApp.RequestLogger do
  @behaviour BeamWeaver.Agent.Middleware

  require Logger

  def name(_middleware), do: :request_logger

  def before_model(state, runtime) do
    user_id = get_in(runtime.context || %{}, [:user_id])
    thread_id = get_in(runtime.execution || %{}, [:thread_id])
    messages = Map.get(state, :messages, Map.get(state, "messages", []))

    Logger.info("user=#{user_id} thread=#{thread_id} messages=#{length(messages)}")

    nil
  end
end
```

Wrap-style middleware reads runtime through the request struct:

```elixir
defmodule MyApp.DynamicUserPrompt do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest

  def name(_middleware), do: :dynamic_user_prompt

  def wrap_model_call(%ModelRequest{} = request, handler) do
    user_name = get_in(request.runtime.context || %{}, [:user_name]) || "there"
    prompt = "You are helpful. Address the user as #{user_name}."

    request
    |> ModelRequest.override(system_prompt: prompt)
    |> handler.()
  end
end
```

Middleware can also declare context it requires:

```elixir
def context_schema(_middleware) do
  %{user_id: %{type: :string, required: true}}
end
```

## Store

`runtime.store` is the configured long-term memory store. Configure it on the
agent or pass it at build time:

```elixir
defmodule MyApp.MemoryAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  tools [MyApp.FetchPreferencesTool]
  store BeamWeaver.Memory.ETS.new()
end
```

Use `BeamWeaver.Memory.ETS` for local/test storage and
`BeamWeaver.Memory.Ecto` for durable Postgres-backed storage. Checkpointing is
separate: stores are long-term memory, while checkpointers persist graph state
for a thread.

## Stream Writer

`runtime.stream_writer` emits application-specific stream events from inside
graph nodes or middleware. Prefer `BeamWeaver.Agent.stream_events/3` or
`BeamWeaver.Graph.Compiled.stream_events/3` to consume them as typed envelopes.

```elixir
defmodule MyApp.RetrievalProgress do
  @behaviour BeamWeaver.Agent.Middleware

  def name(_middleware), do: :retrieval_progress

  def before_model(_state, runtime) do
    runtime.stream_writer.(%{phase: :retrieval, progress: 0.25})
    runtime.stream_writer.(%{phase: :reranking, progress: 0.75})

    nil
  end
end
```

Tool progress should use `BeamWeaver.Core.ToolRuntime.emit_output_delta/2` so
the event is associated with the current tool call.

{% hint style="warning" %}
**No `stream_mode: "custom"` Public API**

LangChain's runtime docs describe writing to a `"custom"` stream mode.
BeamWeaver exposes Event Streaming as typed `%BeamWeaver.Stream.Envelope{}`
values. Custom payloads are emitted through the runtime writer and consumed
from `stream_events`, not through public `stream_mode` branching.
{% endhint %}

## Execution Info

Runtime execution metadata identifies the current graph task:

```elixir
def before_model(_state, runtime) do
  info = runtime.execution || %{}

  IO.inspect(%{
    graph: info[:graph],
    node: info[:node],
    step: info[:step],
    task_id: info[:task_id],
    thread_id: info[:thread_id],
    run_id: info[:run_id]
  })

  nil
end
```

Inside tools, the same value is available as
`tool_runtime.execution_info`.

```elixir
handler = fn input, _opts ->
  runtime = input[:tool_runtime] || input["tool_runtime"]
  runtime.execution_info[:thread_id]
end
```

`thread_id` comes from graph config and scopes checkpoints:

```elixir
config = %{"configurable" => %{"thread_id" => "support-thread-1"}}

MyApp.SupportAgent.invoke(input, config: config, context: %{user_id: "user-123"})
```

## Server Info

`server_info` is optional deployment metadata. BeamWeaver can hydrate it from
`configurable` values, or your application can pass equivalent metadata through
the graph boundary.

```elixir
config = %{
  "configurable" => %{
    "thread_id" => "support-thread-1",
    "assistant_id" => "support",
    "graph_id" => "support-v1",
    "langgraph_auth_user" => %{
      "identity" => "user-123",
      "display_name" => "John Smith",
      "permissions" => ["support:read"]
    }
  }
}
```

Middleware can read it:

```elixir
def before_model(_state, runtime) do
  case runtime.server_info do
    %{user: %{identity: user_id}} -> IO.inspect(user_id, label: "authenticated user")
    _other -> :ok
  end

  nil
end
```

{% hint style="info" %}
**No LangGraph Server Dependency**

LangChain's docs describe LangGraph Server metadata. BeamWeaver has a
`server_info` slot with similar semantics, but it is not tied to LangGraph
Server, a hosted SDK, or a remote deployment platform. Phoenix, OTP services,
CLIs, and tests can supply the metadata they need.
{% endhint %}

## Low-Level Runtime Agents

Most applications should use `use BeamWeaver.Agent`, `BeamWeaver.Agent.build/1`,
or `BeamWeaver.Graph`. The lower-level `BeamWeaver.Runtime.Agent` API remains
available for supervised work orchestration outside the agent DSL.

Start a runtime agent process:

```elixir
{:ok, agent} = BeamWeaver.Runtime.Agent.start_child(id: "agent-1")
```

Subscribe to runtime events:

```elixir
:ok = BeamWeaver.Runtime.Agent.subscribe(agent)
```

Start model work:

```elixir
{:ok, work} =
  BeamWeaver.Runtime.Agent.start_model_call(agent, input, fn input, emit ->
    emit.({:delta, "hello"})
    {:ok, {:final, input}}
  end)
```

Subscribers receive process-runtime messages:

```elixir
{:beam_weaver_agent, agent_id, {:stream, work_id, chunk}}
{:beam_weaver_agent, agent_id, {:completed, work_id, result}}
{:beam_weaver_agent, agent_id, {:failed, work_id, error}}
{:beam_weaver_agent, agent_id, {:cancelled, work_id, error}}
```

Tool work can retry recoverable crashes:

```elixir
BeamWeaver.Runtime.Agent.start_tool_call(agent, "lookup", input, fun, max_retries: 1)
```

Every work item gets a trace run ID through the returned work struct. Use
`BeamWeaver.Tracing.get_run/1` or `BeamWeaver.Tracing.get_tree/1` to inspect
trace state.

## Related Guides

- [Agents](agents.md)
- [Context Engineering](context_engineering.md)
- [Tools](tools.md)
- [Middleware](middleware.md)
- [Custom Middleware](custom_middleware.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Event Streaming](event_streaming.md)
- [Short-Term Memory](short_term_memory.md)
- [Long-Term Memory](long_term_memory.md)
- [Graph](graph.md)
