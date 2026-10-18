# Middleware

Middleware is code that runs around an agent's model and tool calls. Use it
for rules that apply to every call, such as logging, a prompt that depends on
the customer, hiding tools, retries, or stopping a run early.

This middleware stops refunds over $100 before the tool runs:

```elixir
defmodule MyApp.RefundLimit do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  @impl true
  def wrap_tool_call(_middleware, %{tool_call: %{name: "issue_refund"} = call} = request, handler) do
    if call.args["amount"] > 100 do
      Message.tool("Refunds over $100 need a supervisor.", tool_call_id: call.id)
    else
      handler.(request)
    end
  end

  def wrap_tool_call(_middleware, request, handler), do: handler.(request)
end
```

`wrap_tool_call/3` receives each tool call and a `handler` that runs it. Call
the handler to let the call through, or return a tool message of your own
instead. Add the middleware to an agent with `middleware`:

```elixir
defmodule MyApp.Tools.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund an order."

  schema do
    field :order_id, :string
    field :amount, :number
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id, "amount" => amount}, _opts),
    do: {:ok, "Refunded $#{amount} on #{order_id}."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001", "amount" => 250}),
      "A $250 refund needs a supervisor. Shall I escalate your ticket?"
    ]

  tools [MyApp.Tools.IssueRefund]
  middleware [MyApp.RefundLimit]
end

alias BeamWeaver.Core.Message

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Please refund $250 on A-1001."]})
result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "Refunds over $100 need a supervisor."
```

## Where middleware runs

An agent calls the model, runs the tools the model asked for, and calls the
model again until it answers without tools. Middleware hooks run at fixed
points of that loop:

```text
before_agent
  -> before_model -> wrap_model_call(model) -> after_model
       -> wrap_tool_call(each tool) -> back to before_model, while the model calls tools
after_agent
```

A middleware module defines only the hooks it needs:

| Hook | Runs | Arguments |
| --- | --- | --- |
| `before_agent/3` | once, when the run starts | `(middleware, state, runtime)` |
| `before_model/3` | before every model call | `(middleware, state, runtime)` |
| `wrap_model_call/3` | around every model call | `(middleware, request, handler)` |
| `after_model/3` | after every model call | `(middleware, state, runtime)` |
| `wrap_tool_call/3` | around every tool call | `(middleware, request, handler)` |
| `after_agent/3` | once, when the run finishes | `(middleware, state, runtime)` |

The first argument is the middleware itself: the module, or the struct for a
middleware with options (see [Add middleware to an agent](#add-middleware-to-an-agent)).
`state` is the agent state, with the conversation in `state.messages`.
`runtime` is a `BeamWeaver.Graph.Runtime` struct; its `context`, `store` and
`config` fields hold what the caller passed to `invoke/2`.

Mark hooks with `@impl true`: the compiler then warns about a misspelled hook
name, which would otherwise never run.

## What hooks return

The four state hooks (`before_*` and `after_*`) return a change to the state:

| Return | Effect |
| --- | --- |
| `nil` | nothing changes |
| `%{key => value}` (or `{:ok, map}`) | updates those keys, each through its reducer, as a node's update does: new `messages` are appended |
| `{:jump, :end, update}` | applies `update` and ends the run |
| `{:jump, :model, update}` | applies `update` and calls the model next |
| `{:jump, :tools, update}` | applies `update` and runs the tool calls of the last assistant message next |
| `{:error, %BeamWeaver.Core.Error{}}` | stops the run; `invoke/2` returns the error |
| a `BeamWeaver.Graph.Command` | applies its `update`; with `graph: Command.parent()`, its `goto` routes the parent graph ([Subgraphs](subgraphs.md#jump-to-a-parent-node)) |

Return only the keys you change. Returning the whole state would also write
read-only keys such as `remaining_steps`, and the run fails with an
`:invalid_update` error.

The two wrap hooks receive a request and a `handler` that performs the call.
Call it once, several times (to retry), or not at all:

- `wrap_model_call/3` gets a `BeamWeaver.Agent.ModelRequest` with `messages`,
  `system_message`, `tools`, `model`, `state` and `runtime`. Change it with
  `BeamWeaver.Agent.ModelRequest.override/2` before calling the handler; a
  `model:` can be a chat model or a `"provider:model"` string. The
  handler returns `{:ok, %BeamWeaver.Agent.ModelResponse{}}` or
  `{:error, error}`; return that, a changed response, or an assistant message
  to answer without calling the model.
- `wrap_tool_call/3` gets a `BeamWeaver.Agent.ToolCallRequest` whose
  `tool_call` has the `name`, `args` and `id` of the call. The handler returns
  the tool message, or the tool's `%BeamWeaver.Graph.Command{}` when the tool
  updates state. Return that, or your own `BeamWeaver.Core.Message.tool/2`
  message with the same `tool_call_id` to skip the tool.

## Write middleware

### Logging and metrics

A wrap hook can time the call and report it; a state hook can keep a count in
the state:

```elixir
defmodule MyApp.Metrics do
  use BeamWeaver.Agent.Middleware

  @impl true
  def wrap_model_call(_middleware, request, handler) do
    started = System.monotonic_time()
    result = handler.(request)
    duration = System.monotonic_time() - started
    :telemetry.execute([:my_app, :agent, :model_call], %{duration: duration}, %{})
    result
  end

  @impl true
  def after_model(_middleware, state, _runtime) do
    %{model_calls: Map.get(state, :model_calls, 0) + 1}
  end
end

defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday."
    ]

  tools [MyApp.Tools.LookupOrder]
  middleware [MyApp.Metrics]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
result.model_calls
#=> 2
```

Attach a `:telemetry` handler in your application to send the durations to
your metrics system. BeamWeaver also emits its own events and traces; see
[Tracing](tracing.md#metrics-with-telemetry).

### A prompt that depends on the customer

`wrap_model_call/3` can rewrite the system prompt for each call. This one
reads the customer's plan from the runtime context:

```elixir
defmodule MyApp.PlanPrompt do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest

  @impl true
  def wrap_model_call(_middleware, request, handler) do
    plan = request.runtime.context[:plan] || :free
    prompt = "#{ModelRequest.system_prompt(request)}\nThe customer is on the #{plan} plan."

    request
    |> ModelRequest.override(system_prompt: prompt)
    |> handler.()
  end
end
```

The model's answer doesn't show the prompt, so check the effect by calling the
hook with a request and a handler that returns the prompt it receives:

```elixir
alias BeamWeaver.Agent.ModelRequest

request =
  ModelRequest.new(
    system_prompt: "You are Acme's support agent.",
    runtime: %BeamWeaver.Graph.Runtime{context: %{plan: :pro}}
  )

MyApp.PlanPrompt.wrap_model_call(MyApp.PlanPrompt, request, &ModelRequest.system_prompt/1)
#=> "You are Acme's support agent.\nThe customer is on the pro plan."
```

To replace the whole system prompt with the result of a function, use the
built-in `DynamicPrompt` middleware ([Built-in Middleware](builtin_middleware.md#dynamicprompt)).

### Hide tools

Override `tools` to change what the model may call. This middleware offers
`issue_refund` only to supervisors:

```elixir
defmodule MyApp.SupervisorTools do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Tool

  @impl true
  def wrap_model_call(_middleware, request, handler) do
    if request.runtime.context[:role] == :supervisor do
      handler.(request)
    else
      tools = Enum.reject(request.tools, &(Tool.name(&1) == "issue_refund"))
      request |> ModelRequest.override(tools: tools) |> handler.()
    end
  end
end

request =
  ModelRequest.new(
    tools: [MyApp.Tools.LookupOrder, MyApp.Tools.IssueRefund],
    runtime: %BeamWeaver.Graph.Runtime{context: %{role: :agent}}
  )

MyApp.SupervisorTools.wrap_model_call(MyApp.SupervisorTools, request, fn request ->
  Enum.map(request.tools, &BeamWeaver.Core.Tool.name/1)
end)
#=> ["lookup_order"]
```

Change `tools` with `override/2`, as here: it also unregisters the hidden
tools, so if the model calls one anyway, the call gets a "tool is not
registered" error. Setting the field directly (`%{request | tools: tools}`)
only hides them from the model. The built-in `ToolSelection` middleware covers
allow and deny lists, tags and model-based selection
([Built-in Middleware](builtin_middleware.md#toolselection)).

### End the run early

A state hook that returns `{:jump, :end, update}` ends the run. Here a
suspended account gets an answer without a model call:

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

  model "fake:chat", responses: ["How can I help?"]
  middleware [MyApp.SuspendedAccounts]
end

{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["Where is my order?"]},
    context: %{account_status: :suspended}
  )

Enum.map(result.messages, &{&1.role, Message.text(&1)})
#=> [user: "Where is my order?", assistant: "Your account is suspended. Please contact billing."]
```

A jump from `before_agent` or `before_model` also skips the `after_agent`
hooks. To fail the run instead, return
`{:error, BeamWeaver.Core.Error.new(:suspended, "...")}`.

### Send the model back

A jump to `:model` calls the model again, after the `before_model` hooks when
it comes from `after_model`, and a jump to `:tools` runs the tool calls of the
last assistant message. A jump applies to the next step only; after it, the
agent routes as usual. A jump skips the hooks of its kind that haven't run
yet: with `middleware [A, B]`, a jump from `A.before_model` skips
`B.before_model`, and a jump to `:model` or `:end` from `B.after_model` skips
`A.after_model` (see [Order](#order)). Tool calls reach the tools only after
every `after_model` hook, such as the review that `interrupt_on` adds, has
seen them, even after a jump to `:tools`. Here an `after_model` hook sends a
reply that shows a card number back to the model, with a note:

```elixir
defmodule MyApp.NoCardNumbers do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  @impl true
  def after_model(_middleware, %{messages: messages}, _runtime) do
    if Message.text(List.last(messages)) =~ ~r/\d{4} \d{4}/ do
      {:jump, :model, %{messages: [Message.user("Answer again without the card number.")]}}
    end
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat",
    responses: ["Refunded to card 4111 1111.", "Refunded to your card ending in 1111."]

  middleware [MyApp.NoCardNumbers]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Was my refund sent?"]})
result.messages |> List.last() |> Message.text()
#=> "Refunded to your card ending in 1111."
```

The thread keeps both replies and the note. Like every hook update, the jump's
`messages` are appended to the conversation.

## Order

Middleware runs in the order you list it:

- `before_agent` and `before_model` run first to last.
- `wrap_model_call` and `wrap_tool_call` nest: the first middleware is the
  outermost and sees the call before the others and the result after them.
- `after_model` and `after_agent` run last to first.

For `middleware [A, B]`, one model call looks like this:

```text
A.before_model -> B.before_model -> A.wrap_model_call -> B.wrap_model_call -> model
               -> B.after_model -> A.after_model
```

Middleware switched on by agent fields, such as `interrupt_on` or
`filesystem`, comes before the middleware you list. Order matters when
wrappers combine: list `ModelFallback` before `ModelRetry`, and each model is
retried before the next one is tried.

## Add middleware to an agent

`middleware` takes a list. Each entry is a module, a `{module, options}`
tuple, or a struct you built:

```elixir
defmodule MyApp.ListMiddlewareAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-haiku-4-5"

  middleware [
    MyApp.Metrics,
    {BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 2},
    BeamWeaver.Agent.Middleware.PII.new(type: :email)
  ]
end

{:ok, result} = MyApp.ListMiddlewareAgent.invoke(%{messages: ["Reply with the word ready."]})
true = is_binary(result.messages |> List.last() |> BeamWeaver.Core.Message.text())
```

The same with a block, where `use` takes the module and its options and
`include` adds a list built elsewhere:

```elixir
defmodule MyApp.BlockMiddlewareAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-haiku-4-5"

  middleware do
    use MyApp.Metrics
    use BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 2
    use BeamWeaver.Agent.Middleware.PII, type: :email
  end
end

{:ok, result} = MyApp.BlockMiddlewareAgent.invoke(%{messages: ["Reply with the word ready."]})
true = is_binary(result.messages |> List.last() |> BeamWeaver.Core.Message.text())
```

For `{module, options}`, BeamWeaver calls `module.new(options)` when the
module defines `new/1`, and `struct!(module, options)` otherwise. A bare
module is built the same way with no options, so a module with a struct gets
its defaults; only a module without `new/1` or a struct gets the module itself.
Here is `RefundLimit` again, with the limit as an option. List it as
`{MyApp.RefundLimit, max_amount: 500}`, or as `MyApp.RefundLimit` for the
default of $100:

```elixir
defmodule MyApp.RefundLimit do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  defstruct max_amount: 100

  @impl true
  def wrap_tool_call(%__MODULE__{max_amount: max}, %{tool_call: %{name: "issue_refund"} = call} = request, handler) do
    if call.args["amount"] > max do
      Message.tool("Refunds over $#{max} need a supervisor.", tool_call_id: call.id)
    else
      handler.(request)
    end
  end

  def wrap_tool_call(_middleware, request, handler), do: handler.(request)
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001", "amount" => 250}),
      "Done! $250 is on its way back to you."
    ]

  tools [MyApp.Tools.IssueRefund]
  middleware [{MyApp.RefundLimit, max_amount: 500}]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Please refund $250 on A-1001."]})
result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "Refunded $250 on A-1001."
```

Listed as a bare module, it gets the default struct, so the same refund
needs a supervisor:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001", "amount" => 250}),
      "A $250 refund needs a supervisor. Shall I escalate your ticket?"
    ]

  tools [MyApp.Tools.IssueRefund]
  middleware [MyApp.RefundLimit]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Please refund $250 on A-1001."]})
result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "Refunds over $100 need a supervisor."
```

Each middleware in an agent needs its own name: two with the same name and a
state hook make `invoke/2` return an `:invalid_graph` error. The name defaults
to the module name, or to its last part (`"RefundLimit"`) for a struct. To
list one middleware twice, override `name/1`, for example
`def name(%{max_amount: max}), do: "refund_limit_#{max}"`.

## Add tools and state

Besides hooks, a middleware can override these callbacks:

| Callback | Returns |
| --- | --- |
| `tools/1` | tools the middleware adds to the agent |
| `state_schema/1` | state keys it uses, with how updates merge |
| `context_schema/1` | context keys it needs ([Runtime Context](runtime_context.md)) |
| `requires_checkpointer?/1` | `true` if it pauses runs and needs a checkpointer |
| `name/1` | a unique name in the agent |

This middleware gives the agent an `add_note` tool and a `notes` list. The
reducer `&Kernel.++/2` appends each update to the list instead of replacing
it:

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

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("add_note", %{"note" => "Package arrived damaged."}),
      FakeChatModel.tool_call("add_note", %{"note" => "Customer wants a refund."}),
      "I've noted everything for our refunds team."
    ]

  middleware [MyApp.TicketNotes]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["My package arrived damaged."]})
result.notes
#=> ["Package arrived damaged.", "Customer wants a refund."]
```

A key without a schema works too, and each update replaces its value.
`BeamWeaver.Graph.private_channel/2` declares a key that stays out of the
result; it lasts one run, unless you pass `checkpoint: true` to save it with
the thread, as the call-limit middleware do with their thread counts. Hooks
see a private key in the state; tools and subagents don't, unless a tool
names it with `{:state, key}` ([Tools](tools.md#injected-arguments)).
[Graph State](graph_state.md) lists the channels.

## Test middleware

Hooks are plain functions, so test them by calling them. Give a state hook a
state map and a runtime, and a wrap hook a request and a handler that returns
what you need:

```elixir
MyApp.Metrics.after_model(MyApp.Metrics, %{model_calls: 2}, %BeamWeaver.Graph.Runtime{})
#=> %{model_calls: 3}
```

```elixir
call = %{id: "call_1", name: "issue_refund", args: %{"order_id" => "A-1001", "amount" => 900}}
request = %BeamWeaver.Agent.ToolCallRequest{tool_call: call}

MyApp.RefundLimit.wrap_tool_call(%MyApp.RefundLimit{}, request, fn _ -> raise "must not run" end)
|> Message.text()
#=> "Refunds over $100 need a supervisor."
```

Then test the agent end to end with a scripted model, as on this page. See
[Testing](testing.md) for ExUnit patterns.

## Reference

- [`BeamWeaver.Agent.Middleware`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.html): the middleware behaviour and its callbacks
- [`BeamWeaver.Agent.ModelRequest`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.ModelRequest.html): the request passed to `wrap_model_call/3`
- [`BeamWeaver.Agent.ModelResponse`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.ModelResponse.html): the model result a handler returns
- [`BeamWeaver.Agent.ToolCallRequest`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.ToolCallRequest.html): the request passed to `wrap_tool_call/3`
- [`BeamWeaver.Graph.Runtime`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Runtime.html): context, store and config of a run
- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): `channel/2` and `private_channel/2` for state schemas
