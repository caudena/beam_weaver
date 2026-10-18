# Runtime Context

Runtime context is data about the current call that isn't part of the
conversation, such as the customer's id, plan or permissions. You pass it
with `context:` on each call; tools, middleware and prompts read it, and the
model never sees it unless you put it in a prompt.

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up one of the current customer's orders by its id."

  injected :context, :context

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id, context: context}, _opts) do
    {:ok, "Order #{order_id} (customer #{context.customer_id}) shipped on Monday."}
  end
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

  context_schema do
    field :customer_id, :string, required: true
    field :plan, :atom
  end
end

alias BeamWeaver.Core.Message

{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]},
    context: %{customer_id: "cus_ada", plan: :pro}
  )

result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "Order A-1001 (customer cus_ada) shipped on Monday."
```

The customer id comes from your application, for example from the logged-in
session, never from the model. A tool that takes it from context can't be
talked into reading another customer's orders.

## Pass context

`context:` is a map, accepted by `invoke/2`, `stream_events/2`, `resume/2`
and `resume_review/2`. Put anything there that describes the caller rather
than the conversation: ids, roles, feature flags, locale.

> Context is not saved with the thread. Pass it again on every call to the same
> thread, including `resume/2` and `resume_review/2` after an interrupt. Without
> it, a resume fails with `:invalid_context` when the context schema has
> required fields; otherwise tools and middleware see `nil`.

Subagents receive the context of the agent that calls them
([Subagents](subagents.md)).

## Declare the context an agent needs

`context_schema` lists the keys the agent expects, with `field name, type`.
BeamWeaver checks the context before the run starts, so a missing or wrong
value fails at once with a clear error instead of deep inside a tool:

```elixir
MyApp.SupportAgent.invoke(%{messages: ["Where is my order?"]})
#=> {:error,
#    %BeamWeaver.Core.Error{
#      type: :invalid_context,
#      message: "agent context is missing required field",
#      details: %{field: :customer_id}
#    }}
```

A value of the wrong type fails the same way (`"agent context field has
invalid type"`). Context fields are optional unless you write
`required: true`, the opposite of tool arguments.

| Type | Accepts |
| --- | --- |
| `:string`, `:integer`, `:boolean`, `:atom` | that kind of value |
| `:number`, `:float`, `:decimal` | any number; `:decimal` also a `Decimal` |
| `:date`, `:time`, `:utc_datetime`, `:naive_datetime` | a `Date`, `Time`, `DateTime` or `NaiveDateTime` |
| `:map`, `:list` | any map or list |
| `{:list, type}` | a list of values of `type` |
| `{:nullable, type}` | `type` or `nil` |
| `{:union, [type, ...]}` | a value of any of the types |
| a struct module, such as `MyApp.Accounts.User` | that struct |
| `:any` | anything |

A type that is none of these, such as a misspelled atom, fails the call with
an `:invalid_agent` error. The context may use string keys, as when it comes
from JSON: a declared field given under a string key reaches your tools and
middleware under its atom key, so they read `context.customer_id` either way.
Keys the schema doesn't declare stay as you passed them:

```elixir
{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]},
    context: %{"customer_id" => "cus_ada", "plan" => :pro}
  )

result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "Order A-1001 (customer cus_ada) shipped on Monday."
```

## Read context in tools

Declare `injected :context, :context`, as above, and the tool gets the
context map under `context`. A tool can also inject the whole
`BeamWeaver.Core.ToolRuntime` with `injected :runtime, :tool_runtime` and
read `runtime.context` there. See [Tools](tools.md#injected-arguments).

## Read context in middleware

State hooks read it from their `runtime` argument (`runtime.context`); wrap
hooks from the request (`request.runtime.context`). A middleware that needs a
key declares it with `context_schema/1`, and the agent checks it together
with its own `context_schema`:

```elixir
defmodule MyApp.SupervisorRefunds do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Schema
  alias BeamWeaver.Core.Message

  @impl true
  def context_schema(_middleware), do: %{role: Schema.field(:role, :atom, required: true)}

  @impl true
  def wrap_tool_call(_middleware, %{tool_call: %{name: "issue_refund"} = call} = request, handler) do
    if request.runtime.context.role == :supervisor do
      handler.(request)
    else
      Message.tool("Only a supervisor can issue refunds.", tool_call_id: call.id)
    end
  end

  def wrap_tool_call(_middleware, request, handler), do: handler.(request)
end

defmodule MyApp.Tools.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund an order."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Refunded #{order_id}."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001"}),
      "A supervisor needs to approve this refund. I've let them know."
    ]

  tools [MyApp.Tools.IssueRefund]
  middleware [MyApp.SupervisorRefunds]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Refund A-1001"]}, context: %{role: :agent})
result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "Only a supervisor can issue refunds."
```

Without `role`, `invoke/2` returns an `:invalid_context` error before the
model is called.

## Use context in the prompt

The model only sees context that you write into a message or the system
prompt. The built-in `DynamicPrompt` middleware replaces the system prompt
with the result of a function of the state and the runtime:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.DynamicPrompt

  model "fake:chat", responses: ["As a Pro customer, your returns are free."]
  middleware [{DynamicPrompt, prompt: &__MODULE__.prompt/2}]

  context_schema do
    field :plan, :atom, required: true
  end

  def prompt(_state, runtime) do
    "You are Acme's support agent. The customer is on the #{runtime.context.plan} plan."
  end
end

{:ok, _result} = MyApp.SupportAgent.invoke(%{messages: ["Are returns free?"]}, context: %{plan: :pro})

MyApp.SupportAgent.prompt(%{}, %BeamWeaver.Graph.Runtime{context: %{plan: :pro}})
#=> "You are Acme's support agent. The customer is on the pro plan."
```

See [Built-in Middleware](builtin_middleware.md#dynamicprompt) and, for a
prompt that adds to the agent's `system_prompt`,
[Middleware](middleware.md#a-prompt-that-depends-on-the-customer).

## Context, state, config and store

| | Holds | Saved | Pass it with |
| --- | --- | --- | --- |
| Context | facts about the caller: ids, roles, plan | no, pass it on every call | `context:` |
| State | the conversation and the keys tools and middleware update | per thread, by the checkpointer | the input map |
| Config | settings of the run, such as the `thread_id` | used to find the thread | `config:` |
| Store | long-term records shared by all threads | yes, in the store | `store:` |

Use context for what your application knows before the call, state for what
the run learns, and the store for what should outlive the thread. Context can
also carry dependencies that tools need for one call, such as the retriever
that [`search_help_center`](retrieval.md#agentic-retrieval) searches.

## Per-customer memory

Context and the store work together for long-term memory: the store keeps
each customer's records under a namespace, and the customer id in context
picks the namespace. The model chooses what to save but never whose record it
is:

```elixir
defmodule MyApp.Tools.SaveContactPreference do
  use BeamWeaver.Tool

  name "save_contact_preference"
  description "Remember how the current customer wants to be contacted."

  injected :context, :context
  injected :store, :store

  schema do
    field :channel, :string, enum: ["email", "phone"]
  end

  @impl true
  def invoke(_tool, %{"channel" => channel, context: context, store: store}, _opts) do
    {:ok, _item} = BeamWeaver.Memory.put(store, ["customers", context.customer_id], "contact", channel)
    {:ok, "Saved: contact by #{channel}."}
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("save_contact_preference", %{"channel" => "email"}),
      "Got it, we'll email you from now on."
    ]

  tools [MyApp.Tools.SaveContactPreference]

  context_schema do
    field :customer_id, :string, required: true
  end
end

store = BeamWeaver.Memory.ETS.new()

{:ok, _result} =
  MyApp.SupportAgent.invoke(%{messages: ["Please email me instead of calling."]},
    store: store,
    context: %{customer_id: "cus_ada"}
  )

{:ok, item} = BeamWeaver.Memory.get(store, ["customers", "cus_ada"], "contact")
item.value
#=> "email"
```

Another customer's namespace stays empty, and a later thread for Ada finds
the preference. [Long-Term Memory](long_term_memory.md) covers namespaces and
search.

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): `context_schema` and the `context:` option of `invoke/3`
- [`BeamWeaver.Agent.Schema`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Schema.html): context fields for middleware
- [`BeamWeaver.Graph.Runtime`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Runtime.html): the runtime that middleware hooks receive
- [`BeamWeaver.Core.ToolRuntime`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.ToolRuntime.html): the runtime a tool can inject
- [`BeamWeaver.Memory`](https://hexdocs.pm/beam_weaver/BeamWeaver.Memory.html): the long-term memory store API
