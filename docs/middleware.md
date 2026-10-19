# Middleware DSL

Middleware changes how an agent runs without changing its tools or model.
Use it for cross-cutting policies: request context, model selection, retries,
metrics, state updates and stopping conditions. Start with
[Built-in Middleware](builtin_middleware.md); write a hook when you need
application-specific behavior.

Complete [Installation](installation.md). This page's example makes real
OpenAI calls and records how many model turns the agent completed.

## Write and attach a hook

```elixir
defmodule MyApp.CountModelCalls do
  use BeamWeaver.Agent.Middleware

  @impl true
  def after_model(_middleware, state, _runtime) do
    %{completed_model_calls: Map.get(state, :completed_model_calls, 0) + 1}
  end
end

defmodule MyApp.InstrumentedAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Answer briefly."

  middleware do
    use MyApp.CountModelCalls
    use BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 2
  end
end

{:ok, result} = MyApp.InstrumentedAgent.invoke(%{messages: ["What is a tracking number?"]})
1 = result.completed_model_calls
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

A hook returns only changed keys. Returning the entire state can attempt to
write read-only runtime fields and fail with `:invalid_update`.
Use `@impl true` so the compiler checks callback names and arities.

## Where middleware runs

```text
before_agent
  before_model -> wrap_model_call -> after_model
    wrap_tool_call for each requested tool
    repeat the model step while tools are requested
after_agent
```

| Hook | Scope | Arguments after the middleware value |
| --- | --- | --- |
| `before_agent/3`, `after_agent/3` | Run boundaries | State, runtime |
| `before_model/3`, `after_model/3` | Model turns | State, runtime |
| `wrap_model_call/3` | Model invocation | Model request, handler |
| `wrap_tool_call/3` | Individual action | Tool-call request, handler |

The first argument is the configured middleware module or struct. The runtime
contains caller context, configuration and storage. Boundary hooks are not
unconditional cleanup callbacks: a short circuit or failure can bypass later
hooks. Use `try/after` around resources you own.

## Order

Before hooks run in declaration order. After hooks run in reverse order.
Wrappers nest, with the first entry outermost. For `[A, B]`, A sees the request
before B and receives B's result afterward.

Agent capability middleware, such as filesystem or review behavior, is added
before explicitly listed middleware. Ordering affects policy: fallback outside
retry gives each selected model its own retry attempts. Document the intended
ordering whenever policies depend on one another.

## What hooks return

| State-hook return | Effect |
| --- | --- |
| `nil` | No change |
| A map or `{:ok, map}` | Merge changed keys through their reducers |
| `{:jump, :end, update}` | Apply the update and end the run |
| `{:jump, :model, update}` | Route back to the model |
| `{:jump, :tools, update}` | Route toward requested tool execution |
| `{:error, error}` | Fail the run |
| `BeamWeaver.Graph.Command` | Update state and optionally route a parent graph |

Messages are appended by their reducer. To replace or remove them, use the
message update operations in [Conversation History](short_term_memory.md).
A jump skips remaining hooks of the current kind. Tool requests still pass
through the after-model review path before execution.

End a suspended-account run before sending a provider request. This is an application policy, not a provider failure:

```elixir
defmodule MyApp.SuspendedAccounts do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  @impl true
  def before_agent(_middleware, _state, runtime) do
    if runtime.context[:account_status] == :suspended do
      {:jump, :end, %{messages: [Message.assistant("Your account is suspended. Please contact billing.")]}}
    end
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  middleware [MyApp.SuspendedAccounts]
end

{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["Where is my order?"]},
    context: %{account_status: :suspended}
  )

Enum.map(result.messages, &{&1.role, BeamWeaver.Core.Message.text(&1)})
#=> [user: "Where is my order?", assistant: "Your account is suspended. Please contact billing."]
```

Model wrappers receive `BeamWeaver.Agent.ModelRequest`. Their handler returns
`{:ok, BeamWeaver.Agent.ModelResponse}` or an error. Return that result, modify
it, or short-circuit with an assistant message. Tool wrappers receive
`BeamWeaver.Agent.ToolCallRequest`; their handler returns a tool message or
command. A replacement tool message must answer the original `tool_call_id`.

Wrappers and tools jump with `BeamWeaver.Agent.jump/2`, which returns a
`BeamWeaver.Graph.Command` holding the update and the jump:

| Returned by | Effect |
| --- | --- |
| A tool, or a tool wrapper in place of the tool message | `:end` ends the run after the round's tool calls; `:model` sends their results to the model, also from a tool that returns directly |
| A model wrapper, as the `command` of a `BeamWeaver.Agent.ExtendedModelResponse` | `:end` or `:model` applies after the reply and skips the `after_model` hooks |

The update's messages must answer the call with a tool message. In a tool,
`Message.tool/2` without `tool_call_id:` answers the current call; a tool
wrapper passes `tool_call_id: request.tool_call.id`. This tool ends the run
with its answer:

```elixir
defmodule MyApp.Tools.Escalate do
  use BeamWeaver.Tool

  alias BeamWeaver.Core.Message

  name "escalate"
  description "Hand the conversation to a human support agent."

  schema do
    field :reason, :string
  end

  @impl true
  def invoke(_tool, _args, _opts),
    do: {:ok, BeamWeaver.Agent.jump(:end, %{messages: [Message.tool("A support agent will reply by email.")]})}
end

defmodule MyApp.EscalatingAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Call escalate when the customer asks for a person."
  tools [MyApp.Tools.Escalate]
end

{:ok, result} = MyApp.EscalatingAgent.invoke(%{messages: ["I want to talk to a person."]})
last = List.last(result.messages)
:tool = last.role
"A support agent will reply by email." = BeamWeaver.Core.Message.text(last)
```

## A prompt that depends on the customer

Use `ModelRequest.override/2` to change a request without mutating saved state:

```elixir
defmodule MyApp.LocalePrompt do
  use BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.ModelRequest

  @impl true
  def wrap_model_call(_middleware, request, handler) do
    locale = request.runtime.context.locale
    prompt = ModelRequest.system_prompt(request) <> " Reply in #{locale}."
    request |> ModelRequest.override(system_prompt: prompt) |> handler.()
  end
end

defmodule MyApp.LocalizedAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
  system_prompt "Greet the customer."
  middleware [MyApp.LocalePrompt]

  context_schema do
    field :locale, :string, required: true
  end
end

{:ok, result} = MyApp.LocalizedAgent.invoke(%{messages: ["Say hello."]}, context: %{locale: "Spanish"})
answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = String.contains?(String.downcase(answer), "hola")
```

`DynamicPrompt` replaces the complete prompt using a function of state and
runtime. A custom wrapper can append to the existing instructions instead.
Do not include secrets merely because they are available in context.

## Hide tools and enforce action policy

Override `tools:` with `ModelRequest.override/2` when filtering the available
set. It updates both the model-visible declarations and the execution
registry. Assigning the request's `tools` field directly changes neither.
`ToolSelection` provides allowlists, denylists and selectors.

For checks on the actual requested arguments, use `wrap_tool_call/3` and call
its handler only after authorization. A denial can return an error tool
message with the matching call ID. Perform critical ownership checks in the
tool/data-access layer as well, so direct calls have the same protection.

## Add middleware to an agent

The list form accepts modules, `{module, options}` tuples or constructed
structs. The block form uses `use Module, options`; `include` inserts a list.
For a module with options, BeamWeaver calls `new/1` if provided, otherwise
constructs its struct. A bare module gets default construction where available.

Use a struct for configuration that hooks read. Each middleware with state
hooks needs a unique name; override `name/1` when installing multiple instances
of the same module. Duplicate graph node names fail compilation.

## Add tools and state

Middleware can implement these callbacks in addition to hooks:

| Callback | Purpose |
| --- | --- |
| `tools/1` | Add actions to the agent |
| `state_schema/1` | Declare channels and merge behavior |
| `context_schema/1` | Require trusted caller fields |
| `requires_checkpointer?/1` | Require persistence for pauses |
| `name/1` | Identify this middleware instance |

Use `BeamWeaver.Graph.channel/2` for public state and
`BeamWeaver.Graph.private_channel/2` for bookkeeping. Private values are
excluded from ordinary output and generic state injection. They last one run
unless declared with `checkpoint: true`. Tools can explicitly inject a
private key when needed by the owning middleware.

Reducers combine updates, for example `BinaryOperatorAggregate` with
`&Kernel.++/2` for notes. Without a reducer, concurrent writes to one key fail.
See [Graph State](graph_state.md).

A middleware can install both a tool and a list-reduced state channel:

```elixir
defmodule MyApp.Tools.AddNote do
  use BeamWeaver.Tool

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command

  name "add_note"
  description "Add an internal note to the ticket for the next support agent."

  injected :tool_call_id, :tool_call_id

  schema do
    field :note, :string
  end

  @impl true
  def invoke(_tool, %{"note" => note, tool_call_id: id}, _opts) do
    {:ok, %Command{update: %{notes: [note], messages: [Message.tool("Noted.", tool_call_id: id)]}}}
  end
end

defmodule MyApp.TicketNotes do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate

  @impl true
  def tools(_middleware), do: [MyApp.Tools.AddNote]

  @impl true
  def state_schema(_middleware),
    do: %{notes: Graph.channel({BinaryOperatorAggregate, &Kernel.++/2}, initial: [])}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000

  middleware [MyApp.TicketNotes]
end

{:ok, result} =
  MyApp.SupportAgent.invoke(%{
    messages: [
      "Use add_note twice: first Package arrived damaged. Then Customer wants a refund. Preserve those exact note texts."
    ]
  })

true = "Package arrived damaged." in result.notes
true = "Customer wants a refund." in result.notes
```

## Logging and metrics

A wrapper can measure `handler.(request)` with `System.monotonic_time/0`
and report duration through `:telemetry`. Count completed model turns in
`after_model`, as above; retries inside a wrapper may create several provider
attempts for one turn. Use [Tracing](tracing.md) for per-attempt diagnostics.

A wrapper can emit measurements while preserving the original outcome. This example also handles failures through `after`:

```elixir
defmodule MyApp.ModelMetrics do
  use BeamWeaver.Agent.Middleware
  @impl true
  def wrap_model_call(_middleware, request, handler) do
    started = System.monotonic_time()

    try do
      handler.(request)
    after
      :telemetry.execute([:my_app, :model, :duration], %{duration: System.monotonic_time() - started}, %{})
    end
  end
end

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 128, timeout: 60_000],
    middleware: [MyApp.ModelMetrics]
  )

{:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Say hello briefly."]})
true = byte_size(BeamWeaver.Core.Message.text(List.last(result.messages))) > 0
```

## Test middleware

Hooks are ordinary functions. Unit-test a state hook with state/runtime data,
or a wrapper with a handler that records the received request. Then exercise
it in an agent with a scripted model to verify ordering and state changes.
[Testing](testing.md) contains these patterns; live calls verify the actual
provider integration separately.
