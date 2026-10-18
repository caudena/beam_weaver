# Build an Agent

Give an agent an order lookup tool, inspect its work, and continue the
conversation. Start from the Mix application and OpenAI configuration in
[Installation](installation.md). Each code block builds on the previous one.

## Define the action

A tool is an Elixir module that exposes an action to the model. Save this as
`lib/my_app/tools/lookup_order.ex`:

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Get the shipping status and delivery date for an order ID."

  schema do
    field :order_id, :string, description: "An order ID, for example A-1001"
  end

  @impl true
  def invoke(_tool, %{"order_id" => "A-1001"}, _opts) do
    {:ok, %{order_id: "A-1001", status: "shipped", delivery_day: "Thursday"}}
  end

  def invoke(_tool, %{"order_id" => id}, _opts) do
    {:ok, %{order_id: id, status: "not_found"}}
  end
end

{:ok, %{status: "shipped", delivery_day: "Thursday"}} =
  BeamWeaver.Core.Tool.invoke(MyApp.Tools.LookupOrder, %{"order_id" => "A-1001"})
```

This tutorial uses a small local dataset. Replace the function body with your
application's lookup when you integrate it. The schema describes the inputs
the model may send; fields are required unless `required: false` is set.
Model-provided argument keys are strings. The tool returns `{:ok, value}`
or `{:error, reason}`.

The direct call above runs the same tool implementation without asking a
model. It makes debugging an action independent of a conversation.

## Give the agent its tool

Save this as `lib/my_app/support_agent.ex`, replacing the quickstart agent:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Look up orders before answering questions about them. Report the returned delivery day. Never invent a status."

  tools do
    tool MyApp.Tools.LookupOrder
  end

  validate_tools true
  tool_timeout 5_000
  recursion_limit 10
end
```

`tools do` lists the actions available to this agent. The equivalent short
form is `tools [MyApp.Tools.LookupOrder]`. `validate_tools` checks arguments
before executing a call. The timeout limits the tool; the recursion limit
bounds graph steps, not tokens or wall-clock time.

## Ask and inspect

In `iex -S mix`, run:

```elixir
{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Look up order A-1001. Which day will it arrive?"]})

calls = for message <- result.messages, call <- message.tool_calls || [], do: call
true = Enum.any?(calls, &(&1.name == "lookup_order" and &1.args["order_id"] == "A-1001"))
true = Enum.any?(result.messages, &(&1.role == :tool))

answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = String.contains?(answer, "Thursday")
IO.puts(answer)
```

The model requests `lookup_order`; BeamWeaver runs it and passes its result
back. The loop ends when the model answers without requesting more tools.
The checks above verify that the action actually happened and informed the
answer. A convincing answer alone would not establish that the tool ran.

## Continue the conversation

Create one checkpointer, then reuse it with the same thread ID:

```elixir
saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "support-A-1001"}}]

{:ok, first} = MyApp.SupportAgent.invoke(%{messages: ["Look up order A-1001 and tell me its delivery day."]}, opts)
{:ok, second} = MyApp.SupportAgent.invoke(%{messages: ["Repeat that delivery day, please."]}, opts)

true = length(second.messages) > length(first.messages)
answer = second.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = String.contains?(answer, "Thursday")
```

The checkpointer retains the thread between calls. ETS tables belong to the
process that creates them, so this saver lives as long as your IEx process.
Do not create a new saver inside a DSL declaration: declarations are evaluated
on each call. Use database-backed storage for history that must survive a
restart; [Storage](storage.md) includes repository setup and migrations.

## Extend the agent

Add one capability at a time:

| Need | Continue with |
| --- | --- |
| Typed final results | [Structured Output](structured_output.md) |
| Per-request user or tenant data | [Runtime Context](runtime_context.md) |
| Progress while the model works | [Streaming](streaming.md) |
| Approval before an action | [Human-in-the-Loop](human_in_the_loop.md) |
| Reliable retries and limits | [Built-in Middleware](builtin_middleware.md) |
| A workflow whose steps you control | [Graphs](graphs.md) |
| Tests that do not call a provider | [Testing](testing.md) |

The [Agents](agents.md) reference covers all declarations and invocation
options. Tests should assert what your application needs, including tool
arguments and state changes, rather than an exact model-generated sentence.
