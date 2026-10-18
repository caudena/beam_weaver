# Tools

A tool is an Elixir module that a model can call: a name, a description, an
argument schema, and an `invoke/3` function that does the work. Give tools to
an agent so it can read your data and act on it, such as looking up an order
or issuing a refund.

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  alias BeamWeaver.Core.Error

  name "lookup_order"
  description "Look up the shipping status of an order by its id, such as A-1001."

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => "A-" <> _ = order_id}, _opts),
    do: {:ok, "Order #{order_id} shipped on Monday."}

  def invoke(_tool, %{"order_id" => order_id}, _opts),
    do: {:error, Error.new(:not_found, "No order #{order_id}. Order ids look like A-1001.")}
end

BeamWeaver.Core.Tool.invoke(MyApp.Tools.LookupOrder, %{"order_id" => "A-1001"})
#=> {:ok, "Order A-1001 shipped on Monday."}
```

The model reads the name, the description and the schema to decide when to
call the tool and with which arguments, so write the description for the
model. `invoke/3` receives the arguments under string keys, the way the model
sends them as JSON, and returns `{:ok, result}` or `{:error, error}`. Without
`name`, the tool is named after the module in snake case (`lookup_order`), and
without `description`, its `@moduledoc` describes it.

## Give tools to an agent

List the tool modules in the agent's `tools`. When the model asks for a tool,
the agent validates the arguments, runs the tool, and adds the result to the
conversation as a `:tool` message:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday."
    ]

  system_prompt "You are Acme's support agent."
  tools [MyApp.Tools.LookupOrder]
end

alias BeamWeaver.Core.Message

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
tool_message = Enum.find(result.messages, &(&1.role == :tool))
{tool_message.name, Message.text(tool_message)}
#=> {"lookup_order", "Order A-1001 shipped on Monday."}
```

The examples on this page script the fake model for each case, so you can see
what the agent does with each kind of tool result.

## Arguments

`schema do ... end` declares the arguments with `field name, type, opts`.
Every field is required unless you pass `required: false`:

```elixir
defmodule MyApp.Tools.SearchHelpCenter do
  use BeamWeaver.Tool

  name "search_help_center"
  description "Search Acme's help center for policies, such as refunds and returns."

  schema do
    field :query, :string, description: "What the customer wants to know"
    field :section, :string, required: false, enum: ["billing", "shipping", "returns"]
    field :limit, :integer, required: false, default: 3
  end

  @impl true
  def invoke(_tool, %{"query" => query, "limit" => limit} = args, _opts) do
    section = Map.get(args, "section", "all sections")
    {:ok, "Top #{limit} results for #{inspect(query)} in #{section}: Refunds take 5 business days."}
  end
end

alias BeamWeaver.Core.Tool

Tool.invoke(MyApp.Tools.SearchHelpCenter, %{"query" => "refund"})
#=> {:ok, "Top 3 results for \"refund\" in all sections: Refunds take 5 business days."}
```

This tool returns a canned answer; [Retrieval](retrieval.md#agentic-retrieval)
builds a real one on a vector store.

Defaults are filled in before `invoke/3` runs. Arguments with a missing
required field, a wrong type, a value outside `enum:` or out of bounds never
reach it; the call fails with an `:invalid_input` error instead (union members
and date formats aren't checked):

```elixir
Tool.invoke(MyApp.Tools.SearchHelpCenter, %{"query" => "refund", "section" => "toys"})
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_input, message: "tool input is not in enum"}}
```

Field types:

| Type | The model sends |
| --- | --- |
| `:string`, `:integer`, `:boolean` | a string, an integer, `true` or `false` |
| `:number` (or `:float`) | any number |
| `:map` | a JSON object |
| `{:array, type}` | a list of `type`, such as `{:array, :string}` |
| `{:object, fields}` | an object with nested fields: `[{:city, :string}, {:zip, :string, required: false}]` |
| `{:union, types}` | a value of any of `types` |
| `:date`, `:utc_datetime` | an ISO 8601 string |
| `:any` | anything |
| a map | the value your hand-written JSON Schema map allows |

Field options: `required:` (default `true`), `default:`, `description:`,
`enum:` (a list of allowed values) and `nullable: true` (also accepts `null`).

## Results and errors

`invoke/3` returns `{:ok, result}` or `{:error, reason}`. The result decides
what the model reads:

| `invoke/3` returns | The model reads |
| --- | --- |
| `{:ok, "text"}` | the text |
| `{:ok, map_or_list}` | the value encoded as JSON |
| `{:ok, %BeamWeaver.Core.ToolResult{}}` | its `content`; the artifact stays with your app ([Artifacts](#artifacts)) |
| `{:ok, {content, artifact}}`, with `response_format :content_and_artifact` | `content`; the artifact stays with your app ([Artifacts](#artifacts)) |
| `{:ok, %BeamWeaver.Core.Message{role: :tool}}` | its `content`, which can hold content blocks, such as an image from `BeamWeaver.Core.ContentBlock.image/1` |
| `{:ok, %BeamWeaver.Graph.Command{}}` | its tool message; the rest updates state ([Updating state](#updating-state)) |
| `{:error, "reason"}` or `{:error, %BeamWeaver.Core.Error{}}` | `Tool error:`, the reason or error message, and the call's arguments |

An error doesn't stop the agent. It becomes a tool message with
`metadata.status` set to `"error"`, so the model can fix its arguments or
explain the problem; the `ToolError` middleware changes what it reads, or
stops the run (see [Built-in Middleware](builtin_middleware.md#toolerror)).
When an agent runs the tool, an exception raised inside `invoke/3` is
reported the same way (calling a tool module directly with `Tool.invoke/3`
raises it):

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "B-7"}),
      "I couldn't find order B-7. Could you check the id? It looks like A-1001."
    ]

  tools [MyApp.Tools.LookupOrder]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is order B-7?"]})
[_question, _call, tool_message, _answer] = result.messages
{Message.text(tool_message), tool_message.metadata.status}
#=> {"Tool error: No order B-7. Order ids look like A-1001. Args: " <> _, "error"}
```

## Injected arguments

Some inputs must not come from the model: who the customer is, the current
state, the memory store. Declare them with `injected name, source`. The agent
fills them in when it runs the tool, and they are left out of the schema the
model sees:

```elixir
defmodule MyApp.Tools.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund an order of the current customer."

  injected :context, :context

  schema do
    field :order_id, :string
    field :amount, :number
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id, "amount" => amount, context: context}, _opts) do
    {:ok, "Refunded $#{amount} on #{order_id} to #{context.customer_name}'s card."}
  end
end

Tool.input_schema(MyApp.Tools.IssueRefund).properties |> Map.keys() |> Enum.sort()
#=> ["amount", "order_id"]
```

Injected arguments arrive under their atom names (`context`), next to the
string-keyed arguments from the model. The `context:` option of `invoke/2`
supplies this one:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001", "amount" => 25}),
      "Done! $25 is on its way back to your card."
    ]

  tools [MyApp.Tools.IssueRefund]
end

{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["Please refund $25 on A-1001."]},
    context: %{customer_name: "Ada"}
  )

result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "Refunded $25 on A-1001 to Ada's card."
```

| Source | Value |
| --- | --- |
| `:context` | the `context:` map of the call ([Runtime Context](runtime_context.md)) |
| `:state` | the agent state, without private keys |
| `{:state, key}` | one state key, private keys included, or a nested path such as `{:state, [:ticket, :id]}` |
| `:tool_call_id` | the id of this tool call |
| `:store` | the memory store passed with `store:` ([Long-Term Memory](long_term_memory.md)) |
| `:config` | the run config, such as the thread id |
| `:checkpointer` | the checkpointer of the run |
| `:tool_runtime` | a `BeamWeaver.Core.ToolRuntime` struct with all of the above |
| `:runtime` | the run's `BeamWeaver.Graph.Runtime`, for example for its `stream_writer` |

The keys that `:state` leaves out are the agent's bookkeeping, such as token
usage, call counts and the steps left, and keys that middleware declares with
`BeamWeaver.Graph.private_channel/2`. A tool that needs one, such as a
middleware's own tool, names it with `{:state, key}`.

## Updating state

A tool changes the agent's state by returning a `BeamWeaver.Graph.Command`.
Its update must include exactly one tool message that answers the call. A
tool message without a `tool_call_id` gets the call's id; this one injects it
to be explicit:

```elixir
defmodule MyApp.Tools.SetPriority do
  use BeamWeaver.Tool

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command

  name "set_priority"
  description "Set the priority of the current ticket."

  injected :tool_call_id, :tool_call_id

  schema do
    field :priority, :string, enum: ["low", "normal", "urgent"]
  end

  @impl true
  def invoke(_tool, %{"priority" => priority, tool_call_id: id}, _opts) do
    message = Message.tool("Priority set to #{priority}.", tool_call_id: id)
    {:ok, %Command{update: %{priority: priority, messages: [message]}}}
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("set_priority", %{"priority" => "urgent"}),
      "I've marked your ticket as urgent."
    ]

  tools [MyApp.Tools.SetPriority]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["My package arrived broken!"]})
result.priority
#=> "urgent"
```

The new key is part of the state from then on and is saved with the thread
when you use a checkpointer. Each update replaces the old value; to collect
values instead, such as a list of notes, declare the key with a reducer in a
middleware ([Middleware](middleware.md#add-tools-and-state)). When the model
calls several tools at once, each tool's update goes through the key's reducer
in turn; two of them writing the same key without a reducer fail the step, as
two parallel graph nodes would.

## End the run with a tool result

With `return_direct true`, the run ends as soon as the tool succeeds, and its
result is the last message. Use it when the tool's output is the answer, so
the model doesn't need another turn. When the model calls it together with a
tool that doesn't return directly, the model gets all the results and goes
on:

```elixir
defmodule MyApp.Tools.EscalateTicket do
  use BeamWeaver.Tool

  name "escalate_ticket"
  description "Hand the conversation to a human support specialist."
  return_direct true

  schema do
    field :reason, :string
  end

  @impl true
  def invoke(_tool, %{"reason" => reason}, _opts),
    do: {:ok, "A specialist will take over (#{reason}). Expect an email within a day."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [FakeChatModel.tool_call("escalate_ticket", %{"reason" => "refund dispute"})]

  tools [MyApp.Tools.EscalateTicket]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["I want to talk to a person."]})
result.messages |> List.last() |> Message.text()
#=> "A specialist will take over (refund dispute). Expect an email within a day."
```

If the tool fails, the run goes on so the model can react to the error.

## Artifacts

Return a `BeamWeaver.Core.ToolResult` when the model should read a short text
but your application needs more, such as a file, a URL or full records. The
model sees `content`; the artifact is stored in the tool message's
`metadata.artifact`:

```elixir
defmodule MyApp.Tools.GetInvoice do
  use BeamWeaver.Tool

  alias BeamWeaver.Core.ToolResult

  name "get_invoice"
  description "Get the invoice of an order."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts) do
    pdf_url = "https://acme.example/invoices/#{order_id}.pdf"
    {:ok, ToolResult.success("Invoice for #{order_id}: $49.00, paid.", artifact: %{pdf_url: pdf_url})}
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("get_invoice", %{"order_id" => "A-1001"}),
      "Your invoice for A-1001 is attached."
    ]

  tools [MyApp.Tools.GetInvoice]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Can I get my invoice for A-1001?"]})
tool_message = Enum.find(result.messages, &(&1.role == :tool))
{Message.text(tool_message), tool_message.metadata.artifact}
#=> {"Invoice for A-1001: $49.00, paid.", %{pdf_url: "https://acme.example/invoices/A-1001.pdf"}}
```

A tool that always returns both can declare
`response_format :content_and_artifact` and return
`{:ok, {content, artifact}}`. An agent stores the artifact the same way, and
`BeamWeaver.Core.Tool.invoke/3` returns the pair as a `ToolResult`:

```elixir
defmodule MyApp.Tools.GetReceipt do
  use BeamWeaver.Tool

  name "get_receipt"
  description "Get the receipt of an order."
  response_format :content_and_artifact

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts),
    do: {:ok, {"Receipt for #{order_id}: $49.00.", %{lines: [%{sku: "MUG-1", price: 49.0}]}}}
end

BeamWeaver.Core.Tool.invoke(MyApp.Tools.GetReceipt, %{"order_id" => "A-1001"})
#=> {:ok, %BeamWeaver.Core.ToolResult{content: "Receipt for A-1001: $49.00.", artifact: %{lines: [_]}}}
```

## Other options

| DSL call | Effect |
| --- | --- |
| `max_result_chars 2_000` | cuts the text the model reads to 2,000 characters, ending in `[truncated N chars]` |
| `concurrent false` | runs the tool alone, in order, when the model asks for several tools at once (by default they run at the same time) |
| `tags [:billing]` | labels for filtering with `ToolSelection` ([Built-in Middleware](builtin_middleware.md)) |
| `metadata %{owner: "payments"}` | free-form data, also used by `ToolSelection` and tracing |

Use `concurrent false` for a tool that must not overlap with other calls, such
as one that changes the same record.

## Group tools

A toolkit is a module that returns tools that belong together. Implement the
`BeamWeaver.ToolKit` behaviour and list the toolkit in an agent's `tools`,
which then gets every tool it returns:

```elixir
defmodule MyApp.OrderTools do
  @behaviour BeamWeaver.ToolKit

  @impl true
  def tools(_opts), do: [MyApp.Tools.LookupOrder, MyApp.Tools.IssueRefund, MyApp.Tools.GetInvoice]
end
```

```elixir
defmodule MyApp.OrderAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-haiku-4-5"
  tools [MyApp.OrderTools]
end

{:ok, result} = MyApp.OrderAgent.invoke(%{messages: ["Reply with the word ready."]})
true = is_binary(result.messages |> List.last() |> BeamWeaver.Core.Message.text())
```

In a `tools do` block, `tool MyApp.OrderTools, region: "eu"` passes the
options to `tools/1`. A tool that isn't a toolkit takes no options there.

## Built-in tools

BeamWeaver ships tools for deep agents. Most of them come with a capability
you switch on in the agent, which also adds instructions to the prompt:

| Module | Tools | Guide |
| --- | --- | --- |
| `BeamWeaver.Tools.Todo` | `write_todos`, a task list in the agent's state | [Deep Agents](deep_agents.md) |
| `BeamWeaver.Tools.Filesystem` | `ls`, `read_file`, `write_file`, `edit_file`, `glob`, `grep`, and `execute` on a backend that runs commands | [Filesystem](filesystem.md) |
| `BeamWeaver.Tools.FileSearch` | `file_search` over local files or a retriever | [Retrieval](retrieval.md) |
| `BeamWeaver.Tools.Shell` | `shell`, limited to the commands a policy allows | [Sandboxes](sandboxes.md) |
| `BeamWeaver.Tools.Subagents` | `task`, which hands work to a subagent | [Subagents](subagents.md) |

## Call a tool directly

`BeamWeaver.Core.Tool.invoke/3` runs a tool without a model, which is the
quickest way to test one. Pass arguments under string keys, as a model would,
and injected arguments under their atom names:

```elixir
Tool.invoke(MyApp.Tools.IssueRefund, %{
  "order_id" => "A-1001",
  "amount" => 25,
  context: %{customer_name: "Ada"}
})
#=> {:ok, "Refunded $25 on A-1001 to Ada's card."}
```

In ExUnit, write the same calls with `assert`. To test a tool inside an agent,
script the model to call it, as on this page; see [Testing](testing.md).

## Tools built at runtime

When the set of tools comes from data, such as one search tool per help
center section, build them with `BeamWeaver.Core.Tool.from_function!/1`. It
takes a JSON Schema map and a handler function of the arguments and options:

```elixir
defmodule MyApp.HelpCenter do
  alias BeamWeaver.Core.Tool

  def search_tool(section) do
    Tool.from_function!(
      name: "search_#{section}_articles",
      description: "Search Acme's #{section} help articles.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      },
      handler: fn %{"query" => query}, _opts ->
        {:ok, "Top #{section} article for #{inspect(query)}: Refunds take 5 business days."}
      end
    )
  end
end

billing_search = MyApp.HelpCenter.search_tool("billing")
Tool.invoke(billing_search, %{"query" => "refund"})
#=> {:ok, "Top billing article for \"refund\": Refunds take 5 business days."}
```

An agent's `tools` list is evaluated on every call, so it can call functions
that build tools:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("search_billing_articles", %{"query" => "refund"}),
      "Refunds take 5 business days."
    ]

  tools [MyApp.Tools.LookupOrder, MyApp.HelpCenter.search_tool("billing")]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["How long do refunds take?"]})
result.messages |> List.last() |> Message.text()
#=> "Refunds take 5 business days."
```

`from_function!/1` also accepts the options of the DSL: `injected:` (such as
`[context: :context]`), `return_direct:`, `max_result_chars:`, `concurrent:`,
`tags:` and `metadata:`. The handler may return a plain value instead of
`{:ok, value}`, and an exception it raises becomes a `:tool_exception` error.

## Reference

- [`BeamWeaver.Tool`](https://hexdocs.pm/beam_weaver/BeamWeaver.Tool.html): the tool DSL
- [`BeamWeaver.Core.Tool`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Tool.html): the tool behaviour, `invoke/3` and `from_function!/1`
- [`BeamWeaver.Core.ToolResult`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.ToolResult.html): results with artifacts
- [`BeamWeaver.Core.ToolRuntime`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.ToolRuntime.html): runtime data for a tool call
- [`BeamWeaver.Core.Error`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Error.html): tagged errors
- [`BeamWeaver.Graph.Command`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Command.html): state updates from tools
- [`BeamWeaver.ToolKit`](https://hexdocs.pm/beam_weaver/BeamWeaver.ToolKit.html): groups of tools
