# Runtime Context

Pass trusted request data in `context:`: the authenticated account, tenant,
locale or dependencies used by tools. Context is separate from conversation
state. The model sees it only when your code includes it in a prompt or tool
result.

Complete [Installation](installation.md). Run the following modules and calls
in order. The lookup uses a local dataset so it changes no external records.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Scope a tool to the authenticated caller

```elixir
defmodule MyApp.CustomerOrder do
  use BeamWeaver.Tool

  name "customer_order"
  description "Get the current customer's order status."
  injected :context, :context

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id, context: context}, _opts) do
    orders = %{{"cus_ada", "A-1001"} => "shipped"}

    case Map.fetch(orders, {context.customer_id, order_id}) do
      {:ok, status} -> {:ok, %{order_id: order_id, status: status}}
      :error -> {:error, "Order not found for this customer"}
    end
  end
end

defmodule MyApp.CustomerAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Call customer_order before answering order questions."
  tools [MyApp.CustomerOrder]

  context_schema do
    field :customer_id, :string, required: true
    field :locale, :string
  end
end

{:ok, result} =
  MyApp.CustomerAgent.invoke(%{messages: ["Check order A-1001."]},
    context: %{customer_id: "cus_ada", locale: "en"}
  )

tool_result = Enum.find(result.messages, &(&1.role == :tool))
true = BeamWeaver.Core.Message.text(tool_result) =~ "shipped"

{:error, denied} =
  BeamWeaver.Core.Tool.invoke(
    MyApp.CustomerOrder,
    %{"order_id" => "A-1001", context: %{customer_id: "cus_bob"}}
  )

:tool_error = denied.type
"Order not found for this customer" = denied.message
```

The schema exposes only `order_id`. The atom-keyed `context` comes from the
application. **The lookup enforces ownership** by querying with both the
customer ID and order ID. Injection alone does not authorize an operation;
your data access must actually use the trusted identity.

## Pass context

`invoke/2`, `stream_events/2`, `resume/2` and `resume_review/2` all accept
`context:`. Supply it on every call, including continuation after human review.
Context is not stored in checkpoints. Without it, required context fields
fail validation; otherwise tools may receive `nil`.

Subagents inherit the parent's context. Avoid putting secrets in prompts or
returning them from tools merely because they are available in context.

## Declare the context an agent needs

Context fields are optional unless `required: true` is set, unlike tool and
response-schema fields. Validation happens before model execution:

```elixir
{:error, error} = MyApp.CustomerAgent.invoke(%{messages: ["Check my order."]})
:invalid_context = error.type
:customer_id = error.details.field
```

| Type | Accepted data |
| --- | --- |
| `:string`, `:integer`, `:boolean`, `:atom` | The corresponding Elixir value |
| `:number`, `:float`, `:decimal` | Numbers; `:decimal` also accepts `Decimal` |
| `:date`, `:time`, `:utc_datetime`, `:naive_datetime` | Corresponding date/time structs |
| `:map`, `:list`, `{:list, type}` | Collections, optionally typed |
| `{:nullable, type}`, `{:union, types}` | Nullable or alternative types |
| A struct module | An instance of that struct |
| `:any` | Any value |

Declared string keys are normalized to their atom field names. Undeclared
keys retain their original representation. An unknown field type produces
`:invalid_agent`; invalid caller data produces `:invalid_context`.

## Read context in tools

Use `injected :context, :context` for the map, or
`injected :runtime, :tool_runtime` for `BeamWeaver.Core.ToolRuntime`, which
also holds the store, state, configuration and call ID.
[Tools](tools.md#injected-arguments) lists the available sources.

## Read context in middleware

State hooks receive `runtime.context`; wrapper hooks receive
`request.runtime.context`. Middleware can declare required context fields
through `context_schema/1`. BeamWeaver validates those together with the
agent's context schema. See [Middleware](middleware.md).

Validate a required caller role in a hook before any provider request:

```elixir
defmodule MyApp.SupportOnly do
  use BeamWeaver.Agent.Middleware
  @impl true
  def before_agent(_middleware, _state, runtime) do
    if runtime.context[:role] != :support,
      do: {:error, BeamWeaver.Core.Error.new(:forbidden, "Support role required")}
  end
end

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 128, timeout: 60_000],
    middleware: [MyApp.SupportOnly]
  )

{:error, %{type: :forbidden}} = BeamWeaver.Agent.invoke(agent, %{messages: ["Hello"]}, context: %{role: :guest})
{:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Hello"]}, context: %{role: :support})
true = byte_size(BeamWeaver.Core.Message.text(List.last(result.messages))) > 0
```

## Use context in the prompt

`BeamWeaver.Agent.Middleware.DynamicPrompt` accepts a function of state and
runtime. Use it to derive instructions such as the reply language or service
level. A prompt cannot replace authorization inside tools. Return only the
context needed for the model's task. See
[DynamicPrompt](builtin_middleware.md#dynamicprompt).

Pass only the language preference to the model, not the whole caller object:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 128, timeout: 60_000],
    middleware: [
      {BeamWeaver.Agent.Middleware.DynamicPrompt,
       prompt: fn _state, runtime ->
         "Greet the user in #{runtime.context.language}."
       end}
    ]
  )

{:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Hello"]}, context: %{language: "Spanish"})
true = result.messages |> List.last() |> BeamWeaver.Core.Message.text() |> String.downcase() |> String.contains?("hola")
```

## Context, state, config and store

| Data | Lifetime | Typical contents |
| --- | --- | --- |
| Context | One call; resend on resume | Caller identity, locale, request dependencies |
| State | A run or checkpointed thread | Messages, task progress, tool updates |
| Config | Run settings and storage lookup | Thread ID and checkpoint selection |
| Store | Across conversations | Namespaced preferences and records |

## Per-customer memory

Build memory namespaces from trusted context, for example a customer ID,
inside the tool. Do not let the model choose an unrestricted namespace.
Apply the same rule when reading, searching, updating and deleting records.
[Long-Term Memory](long_term_memory.md) shows the full storage flow.
