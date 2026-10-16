# Structured Output

Structured output makes an agent finish with data in a shape you define,
instead of prose you have to parse. Use it when code reads the answer: to
route a ticket, fill in a form, or extract fields from text.

```elixir
defmodule MyApp.Schemas.Triage do
  use BeamWeaver.Schema

  description "How to route a support ticket."

  field :category, :string, enum: ["shipping", "billing", "other"], description: "What the ticket is about"
  field :priority, :string, enum: ["low", "high"]
  field :order_id, :string, required: false, description: "The order id, if the customer gave one"
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [FakeChatModel.final(%{category: "shipping", priority: "high", order_id: "A-1001"})]

  system_prompt "Triage the customer's message."
  response_schema MyApp.Schemas.Triage
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["My order A-1001 never arrived!"]})
result.structured_response
#=> %{"category" => "shipping", "priority" => "high", "order_id" => "A-1001"}
```

`FakeChatModel.final/1` scripts the structured answer, so this runs without an
API key. With a real model, the model fills in the fields.

## Define a schema

A schema is a module with `use BeamWeaver.Schema`. Each `field` has a name, a
type and options:

| Type | JSON |
| --- | --- |
| `:string`, `:integer`, `:number`, `:boolean` | The matching JSON type. |
| `{:array, type}` | A list of values of that type, such as `{:array, :string}`. |
| another schema module | A nested object. |

| Option | Effect |
| --- | --- |
| `required: false` | The field may be missing. Fields are required by default. |
| `description: "..."` | Tells the model what to put there. |
| `enum: [...]` | The allowed values. |
| `nullable: true` | The value may be `null`. |
| `default: value` | A default the model sees in the schema. |

The module can also set a `title`, which names the schema (by default, the
module name in snake case, here `"triage"`), a `description`, and `strict true`
to forbid extra keys. `json_schema/0` returns the JSON Schema that the model
receives:

```elixir
MyApp.Schemas.Triage.json_schema()["required"]
#=> ["category", "priority"]
```

Write descriptions for the model: they are the only instructions it gets for
each field. When a schema comes from data instead of code, `response_schema`
also takes a JSON Schema map.

## Strategies

A model can return structured data in two ways: as JSON, through the
provider's native structured output, or as the arguments of a tool call.
`strategy:` picks the way:

| Strategy | How the answer comes back |
| --- | --- |
| `:auto` (default) | Provider-native output when the model supports it, otherwise the tool strategy. |
| `:provider` | The provider's native structured output: a reply whose text is JSON that matches the schema. It falls back to the tool strategy when the model can't do it. |
| `:tool` | The model calls a tool named after the schema; the call's arguments are the answer. It works with any model that calls tools, and forces the call where the model allows a forced tool choice. |

The check uses the model's profile (see [Models](models.md#model-profiles)):
native output needs `:structured_output`, and native output in an agent that
also has tools needs `:structured_output_with_tools`. Use `:auto` unless you
need one strategy in particular.

With the tool strategy, the conversation shows the tool call and a tool
message that records the answer:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [FakeChatModel.final(%{category: "shipping", priority: "high", order_id: "A-1001"})]

  system_prompt "Triage the customer's message."
  response_schema MyApp.Schemas.Triage, strategy: :tool
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["My order A-1001 never arrived!"]})
Enum.map(result.messages, & &1.role)
#=> [:user, :assistant, :tool]
```

`response_schema` takes these options besides `strategy:`:

| Option | Effect |
| --- | --- |
| `name:` | Names the schema, and the tool in the tool strategy. Overrides the schema's title. |
| `description:` | Replaces the schema's description. |
| `strict:` | Native output asks the provider for strict schema adherence unless you pass `strict: false`. |
| `tool_message_content:` | The text of the tool message that records the answer (tool strategy). |
| `handle_errors: false` | Fails the run on an answer that fails the schema, instead of asking the model again (tool strategy; see [Validation errors and retries](#validation-errors-and-retries)). |
| `max_retries:` | How many times the model may answer again after an answer that fails the schema (tool strategy, default 2). |

`response_format` declares the same thing with a strategy you build from a
schema, such as `BeamWeaver.Agent.StructuredOutput.tool(schema_map)` for a
JSON Schema map with a `"title"`. [Agents built at runtime](agents.md#agents-built-at-runtime)
take the same values, or a schema module, as their `response_format:` option.

## Read the result

`result.structured_response` holds the answer as a map with string keys, the
way the JSON came back. Optional fields the model left out are missing, and
optional fields it set to `null` are dropped. Match on the keys you need:

```elixir
case result.structured_response do
  %{"priority" => "high", "category" => category} -> {:escalate, category}
  %{"category" => category} -> {:queue, category}
end
#=> {:escalate, "shipping"}
```

## Structured output with tools

An agent with tools first works through its tool calls. When the model has an
answer, BeamWeaver calls it once more and asks for the structured answer. A
script for it has three turns:

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} is lost in transit."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Order A-1001 is lost in transit, so this is urgent.",
      FakeChatModel.final(%{category: "shipping", priority: "high", order_id: "A-1001"})
    ]

  system_prompt "Look the order up, then triage the ticket."
  tools [MyApp.Tools.LookupOrder]
  response_schema MyApp.Schemas.Triage
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["My order A-1001 never arrived!"]})
{result.structured_response["priority"], Enum.map(result.messages, & &1.role)}
#=> {"high", [:user, :assistant, :tool, :assistant, :assistant]}
```

The messages are the tool call, its result, the model's answer, and the
structured answer. A model whose profile has `:structured_output_with_tools`
with the `:auto` or `:provider` strategy skips the extra call: its last reply
in the tool loop is the structured answer.

## Validation errors and retries

BeamWeaver checks the top level of each answer against the schema: required
fields must be there, and values must have the declared JSON types. Nested
objects and list items aren't checked. With native output, an answer that
fails the check fails the run:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat", responses: [FakeChatModel.final(%{category: "shipping"})]
  response_schema MyApp.Schemas.Triage
end

MyApp.SupportAgent.invoke(%{messages: ["My order A-1001 never arrived!"]})
#=> {:error, %BeamWeaver.Core.Error{type: :structured_output_validation_error, details: %{missing: ["priority"]}}}
```

The other error types are `:structured_output_parse_error`, for a reply that
is not valid JSON, and, with the tool strategy, `:multiple_structured_outputs`,
when the model gives several answers at once, and `:missing_structured_output`,
when it answers in text instead of calling the schema's tool (a model that
ignores the forced tool call, or can't be forced, such as Kimi with thinking
on).

With the tool strategy, the model gets a failing answer back as an error tool
message that says what is wrong (a user message, for an answer that called no
tool), and answers again. After `max_retries` failing answers in a row (2 by
default), the run fails with the last error, whose `details` count the
`attempts`. Here the second answer is valid:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.final(%{category: "shipping"}),
      FakeChatModel.final(%{category: "shipping", priority: "high"})
    ]

  response_schema MyApp.Schemas.Triage, strategy: :tool
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["My order A-1001 never arrived!"]})
error = Enum.find(result.messages, &(&1.role == :tool))
{BeamWeaver.Core.Message.text(error), result.structured_response["priority"]}
#=> {"Structured output error: structured response is missing required keys (priority). Fix it and answer again.", "high"}
```

`handle_errors: false` fails the run on the first failing answer instead; a
string or a function of the `%BeamWeaver.Core.Error{}` replaces the text of
the error message.

The check doesn't enforce `enum`, number ranges or patterns. Providers that
honor strict schemas enforce them; otherwise check those rules in your code.

To give the model another chance, add the `StructuredOutputRetry` middleware.
It adds the failed answer and the error to the conversation and calls the
model again, up to `max_retries` times (1 by default), so the model sees what
it got wrong. Set `handle_errors: false` so that errors reach the middleware
with every strategy. A script for it has the failed answer, then the
corrected one:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.final(%{category: "shipping"}),
      FakeChatModel.final(%{category: "shipping", priority: "high"})
    ]

  middleware [BeamWeaver.Agent.Middleware.StructuredOutputRetry]
  response_schema MyApp.Schemas.Triage, handle_errors: false
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["My order A-1001 never arrived!"]})
{result.structured_response, Enum.map(result.messages, & &1.role)}
#=> {%{"category" => "shipping", "priority" => "high"}, [:user, :assistant, :user, :assistant]}
```

The saved thread keeps the failed answer and the error after it: a user
message here, or a tool message for each tool call when the answer came
through the tool strategy. `feedback:` replaces the error text the model
gets: a string, in which `{error}` stands for the error message, or a
function that takes the `%BeamWeaver.Core.Error{}` and returns the text.

## Without an agent

`BeamWeaver.Models.with_structured_output/3` wraps a chat model so that each
call returns structured data. It picks a strategy the same way, and the answer
is in the reply's `metadata.structured_response`:

```elixir
alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Models.FakeChatModel

{:ok, model} = BeamWeaver.Models.init_chat_model("fake:chat", responses: [FakeChatModel.final(%{category: "billing", priority: "low"})])
triager = BeamWeaver.Models.with_structured_output(model, MyApp.Schemas.Triage)

{:ok, reply} = ChatModel.invoke(triager, "I was charged twice for order A-1001.")
reply.metadata.structured_response
#=> %{"category" => "billing", "priority" => "low"}
```

An answer that fails the schema returns `{:error, %BeamWeaver.Core.Error{}}`,
as in an agent. To pull JSON or XML out of an ordinary reply instead, use an
[output parser](prompts_and_parsers.md#output-parsers).

## Test with the fake model

`FakeChatModel.final/1` answers the way each request asks: with JSON for
native structured output, or with a call to the schema's tool for the tool
strategy. The same script therefore works with every strategy. To test how
your code handles a bad answer, script one that breaks the schema, as in
[Validation errors and retries](#validation-errors-and-retries).
[Testing](testing.md) covers fake models in more depth.

## Reference

- [`BeamWeaver.Schema`](https://hexdocs.pm/beam_weaver/BeamWeaver.Schema.html): declare schemas with `field`
- [`BeamWeaver.Agent.StructuredOutput`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.StructuredOutput.html): the `auto`, `tool` and `provider` strategies
- [`BeamWeaver.Agent.Middleware.StructuredOutputRetry`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.StructuredOutputRetry.html): retry answers that fail validation
- [`BeamWeaver.Models`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.html): `with_structured_output/3` for direct model calls
- [`BeamWeaver.Models.FakeChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.FakeChatModel.html): script structured answers with `final/1`
