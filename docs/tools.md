# Tool DSL

Tools connect a model to your application's functions. A tool declares a
model-visible name, description and argument schema, then implements
`invoke/3`. The model requests an action; your Elixir code performs it.

Complete [Installation](installation.md). Run this page's blocks in order.
Its local help-center data is illustrative; no external service is modified.

## Define and run an action

```elixir
defmodule MyApp.RefundPolicy do
  use BeamWeaver.Tool

  name "refund_policy"
  description "Read the published refund policy for standard or express shipping."

  schema do
    field :shipping, :string, enum: ["standard", "express"], default: "standard"
  end

  @impl true
  def invoke(_tool, %{"shipping" => shipping}, _opts) do
    {:ok, %{shipping: shipping, refund_days: 5}}
  end
end

alias BeamWeaver.Core.Tool
{:ok, %{shipping: "standard", refund_days: 5}} = Tool.invoke(MyApp.RefundPolicy, %{})
{:error, error} = Tool.invoke(MyApp.RefundPolicy, %{"shipping" => "overnight"})
:invalid_input = error.type
```

Calling a tool directly is useful for debugging without a model. Inputs use
string keys because model arguments arrive as JSON. Tools return
`{:ok, value}` or `{:error, reason}`. Defaults are applied before the handler.
A missing `name` defaults to the module's snake-case name; a missing
`description` falls back to the module documentation.

## Give tools to an agent

```elixir
defmodule MyApp.PolicyAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Read refund_policy before answering. Use the returned number of days."
  tools [MyApp.RefundPolicy]
  validate_tools true
  tool_timeout 5_000
  recursion_limit 10
end

{:ok, result} = MyApp.PolicyAgent.invoke(%{messages: ["How long does a standard-shipping refund take?"]})
call = result.messages |> Enum.flat_map(&(&1.tool_calls || [])) |> Enum.find(&(&1.name == "refund_policy"))
%{"shipping" => "standard"} = call.args
tool_result = Enum.find(result.messages, &(&1.role == :tool and &1.tool_call_id == call.id))
true = BeamWeaver.Core.Message.text(tool_result) =~ "5"
answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = byte_size(answer) > 0
IO.puts(answer)
```

The agent validates the request, invokes the tool and sends its result back
to the model. Descriptions should explain when to use a tool and what its
result means. Authorization and business validation belong inside the handler.

## Arguments

`schema do` groups `field name, type, opts` declarations. Tool declarations
are evaluated when the module compiles. Fields are required by default;
`required: false` makes one optional.

| Type | Model input |
| --- | --- |
| `:string`, `:integer`, `:boolean` | Corresponding JSON value |
| `:number`, `:float` | A number |
| `:map` | An object |
| `{:array, type}` | A list of typed values |
| `{:object, fields}` | Nested fields, for example `[{:city, :string}]` |
| `{:union, types}` | One of several schema types |
| `:date`, `:utc_datetime` | ISO 8601 text |
| `:any` | Any JSON value |
| A JSON Schema map | The constraints described by that map |

Options include `description:`, `default:`, `enum:` and `nullable:`.
Validation rejects missing required values, wrong types, enum violations and
supported numeric bounds. Union members and date formats are not validated;
check application-specific constraints in your code.

This local help-center example supplies an optional section and a default limit:

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

An unsupported section fails before the handler is called:

```elixir
Tool.invoke(MyApp.Tools.SearchHelpCenter, %{"query" => "refund", "section" => "toys"})
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_input, message: "tool input is not in enum"}}
```

## Results and errors

| Handler result | What happens |
| --- | --- |
| `{:ok, text}` | Text becomes the tool result |
| `{:ok, map_or_list}` | Data is JSON-encoded for the model |
| `{:ok, ToolResult}` | Content goes to the model; artifact stays with the application |
| `{:ok, Message.tool(...)}` | The tool message can include media blocks |
| `{:ok, Graph.Command}` | Tool message plus state updates |
| `{:error, reason}` | The agent returns an error tool message to the model |

A tool error normally lets the agent continue: the model may correct its
arguments or explain the failure. Tool messages mark errors in
`metadata.status`. `ToolError` middleware can change that policy.
Exceptions in agent-run tools become tool errors; a direct call to a module's
handler can raise. Function-backed tools normalize handler exceptions to
`:tool_exception`.

## Injected arguments

Declare `injected :context, :context` to receive trusted caller data under
an atom key alongside the model's string keys. Injected fields are excluded
from the model-visible schema.

| Source | Value |
| --- | --- |
| `:context` | The call's trusted context map |
| `:state` | Public agent state |
| `{:state, key_or_path}` | A selected state value, including private channels |
| `:tool_call_id` | ID needed to correlate a result with its request |
| `:store`, `:checkpointer`, `:config` | Call storage and configuration |
| `:tool_runtime` | `BeamWeaver.Core.ToolRuntime` containing tool runtime data |
| `:runtime` | Graph runtime, including its stream writer |

[Runtime Context](runtime_context.md) demonstrates an ownership-scoped lookup.
Use the injected identity in the actual query; injection does not by itself
enforce access control.

## Updating state

Return a command when an action also changes the agent's state. Include
exactly one tool message answering the current call:

```elixir
defmodule MyApp.SetPriority do
  use BeamWeaver.Tool

  name "set_priority"
  description "Set the ticket priority."
  injected :call_id, :tool_call_id

  schema do
    field :priority, :string, enum: ["normal", "urgent"]
  end

  @impl true
  def invoke(_tool, %{"priority" => priority, call_id: id}, _opts) do
    message = BeamWeaver.Core.Message.tool("Priority updated.", tool_call_id: id)
    {:ok, %BeamWeaver.Graph.Command{update: %{priority: priority, messages: [message]}}}
  end
end

defmodule MyApp.PriorityAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Use set_priority for every priority change."
  tools [MyApp.SetPriority]
end

{:ok, result} = MyApp.PriorityAgent.invoke(%{messages: ["Set this ticket's priority to urgent."]})
"urgent" = result.priority
```

Updates replace a value unless a reducer is declared for the channel. Parallel
writes to the same unreduced key fail. [Middleware](middleware.md#add-tools-and-state)
explains agent state channels; [Graph State](graph_state.md) explains reducers.

## Artifacts

Keep large records outside the model's text while retaining them for your app:

```elixir
defmodule MyApp.Receipt do
  use BeamWeaver.Tool

  name "receipt"
  description "Read the sample receipt."
  response_format :content_and_artifact

  @impl true
  def invoke(_tool, _input, _opts),
    do: {:ok, {"Total: 49.00", %{lines: [%{sku: "MUG-1", price: 49.0}]}}}
end

{:ok, receipt} = Tool.invoke(MyApp.Receipt, %{})
"Total: 49.00" = receipt.content
[%{sku: "MUG-1", price: 49.0}] = receipt.artifact.lines
```

Returning `BeamWeaver.Core.ToolResult` directly has the same purpose. An
agent keeps the artifact in the tool message's `metadata.artifact`; providers
receive the content. `Message.tool/2` also supports application-only `artifacts:`.

## End the run with a tool result

`return_direct true` ends the loop after a successful tool result, without
asking the model to rephrase it. Failure still returns to the model. A mixed
batch containing a tool that does not return directly continues normally.
Use this for outputs that your application already formats completely.

A direct-return tool ends the loop with its result. This local example does not actually send an email:

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

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000

  system_prompt "Use escalate_ticket to hand the request to a specialist. Set the reason to refund dispute."
  tools [MyApp.Tools.EscalateTicket]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["I want to talk to a person."]})
last = List.last(result.messages)
:tool = last.role
"escalate_ticket" = last.name
true = BeamWeaver.Core.Message.text(last) =~ "specialist will take over"
```

## Other options

| Declaration | Use |
| --- | --- |
| `concurrent false` | Serialize this tool within a tool batch |
| `max_result_chars 2_000` | Bound model-visible text, with a truncation marker |
| `tags`, `metadata` | Tool selection and trace attributes |
| `provider_opts` | Provider-specific declaration fields |
| `output_schema` | Describe structured tool output |

Concurrency settings are not a database lock across independent runs. Use
transactions or idempotency keys where actions can race or be retried.

## Group tools

A module implementing `BeamWeaver.ToolKit.tools/1` returns a list of tools.
List that toolkit in `tools`, or pass its options with
`tool MyApp.OrderTools, region: "eu"` inside a `tools do` block.
Ordinary tool modules take no options in that position.

A toolkit packages existing tools. Run the same policy lookup through that group:

```elixir
defmodule MyApp.PolicyTools do
  @behaviour BeamWeaver.ToolKit
  @impl true
  def tools(_opts), do: [MyApp.RefundPolicy]
end

defmodule MyApp.ToolkitAgent do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Read refund_policy before answering."
  tools [MyApp.PolicyTools]
end

{:ok, result} = MyApp.ToolkitAgent.invoke(%{messages: ["Read the refund policy for standard shipping."]})
true = Enum.any?(result.messages, &(&1.role == :tool and &1.name == "refund_policy"))
```

## Tools built at runtime

Use `BeamWeaver.Core.Tool.from_function!/1` for dynamic tools. Supply `name:`,
`description:`, a JSON `input_schema:` and a two-argument `handler:` receiving
input and options. It also accepts injection, direct-return, concurrency,
truncation, tags and metadata options. Keep dynamic descriptions and tool
sets within your application's authorization rules.

A runtime tool can close over application configuration. Its local handler is executable without a model:

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

Supply the constructed tool to an agent and verify its call:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 256, timeout: 60_000],
    system_prompt: "Search the billing articles before answering.",
    tools: [billing_search]
  )

{:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Search the refund article."]})
true = Enum.any?(result.messages, &(&1.role == :tool and &1.name == "search_billing_articles"))
```

## Built-in tools

Capability declarations add coordinated tools and instructions: filesystem
operations, task lists, skill discovery and subagent delegation. See
[Deep Agents](deep_agents.md), [Filesystem](filesystem.md),
[Retrieval](retrieval.md) and [Sandboxes](sandboxes.md).

## Call a tool directly

`BeamWeaver.Core.Tool.invoke/3` accepts argument maps or a tool-call value.
With a tool call, it correlates the returned tool message automatically.
[Messages](messages.md#tool-calls-and-tool-results) shows a manual round trip.
[Testing](testing.md) covers direct tool tests and scripted agent tests.
