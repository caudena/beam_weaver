# Schema DSL and Structured Output

Use structured output when application code needs fields it can validate and
act on. A response schema describes the agent's final answer; a tool schema
describes an action's input.

Complete [Installation](installation.md). Define these modules in IEx or save
them under `lib/my_app/`, then run the calls in order with your OpenAI key.

## Extract a typed answer

```elixir
defmodule MyApp.Ticket do
  use BeamWeaver.Schema

  description "Facts explicitly stated in a support ticket."
  field :category, :string, enum: ["shipping", "billing", "other"]
  field :order_id, :string
  field :summary, :string
end

defmodule MyApp.TriageAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Extract the order ID verbatim. Delivery questions belong to shipping."
  response_schema MyApp.Ticket
end

{:ok, result} = MyApp.TriageAgent.invoke(%{messages: ["Where is order A-1001? It has not arrived."]})
%{"category" => "shipping", "order_id" => "A-1001", "summary" => summary} = result.structured_response
true = is_binary(summary) and byte_size(summary) > 0
```

Read `result.structured_response`, a map with string keys. Generated wording
can vary; assert the fields your application actually relies on.

## Define a schema

`use BeamWeaver.Schema` builds JSON Schema at module compilation.
`json_schema/0` returns the schema sent to the provider.

| Declaration | Purpose |
| --- | --- |
| `title "ticket"` | Name the schema; the default comes from the module name |
| `description "..."` | Explain what the answer represents |
| `field :name, type, opts` | Declare a field |
| `strict true` | Forbid additional object properties |

Types include `:string`, `:integer`, `:number`, `:boolean`,
`{:array, type}`, another schema module for a nested object, and a JSON
Schema map such as `%{"type" => "string", "format" => "date"}`. Fields are
required by default. Options include `required: false`, `nullable: true`,
`enum:`, `description:` and `default:`. A `nullable: true` field also accepts
null, and adds `nil` to its `enum:` values. A default is schema metadata;
check the returned value rather than assuming the provider fills it in.
Descriptions guide the model; business rules belong in your application.

```elixir
schema = MyApp.Ticket.json_schema()
true = Enum.sort(schema["required"]) == ["category", "order_id", "summary"]
true = schema["properties"]["category"]["enum"] == ["shipping", "billing", "other"]
```

`response_schema` also accepts a JSON Schema map. Optional fields omitted by
the model remain absent; optional fields returned as null are dropped from
the normalized response.

## Strategies

| Strategy | Behavior |
| --- | --- |
| `:auto` | Use native provider output where supported, otherwise a schema tool |
| `:provider` | Prefer native output; fall back to a schema tool when unavailable |
| `:tool` | Ask the model to call a tool whose arguments match the answer schema |

Selection uses the [model profile](models.md#model-profiles). Native output
alongside ordinary tools requires `:structured_output_with_tools` as well as
`:structured_output`.

Select the tool strategy explicitly when that is your integration contract:

```elixir
defmodule MyApp.ToolTriageAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Extract the order ID verbatim. Duplicate charges belong to billing."
  response_schema MyApp.Ticket, strategy: :tool, max_retries: 2
end

{:ok, result} = MyApp.ToolTriageAgent.invoke(%{messages: ["Order A-1001 was charged twice."]})
%{"category" => "billing", "order_id" => "A-1001"} = result.structured_response
true = Enum.any?(result.messages, &(&1.role == :tool))
```

Other options are `name:`, `description:`, `strict:` and
`tool_message_content:`. `response_format` accepts a strategy built by
`BeamWeaver.Agent.StructuredOutput`. Runtime-built agents use the
`response_format:` option for either a schema or a strategy.

## Structured output with tools

Add ordinary tools as usual. The model can gather facts before answering.
Models supporting native structured output with tools finish within the
normal loop; other combinations need an additional formatting call. Account
for that call in latency, token budgets and recursion limits.

Check successful tool results when the task requires an action. A valid
answer alone does not prove an action happened. The complete
[structured-output example](https://github.com/caudena/beam_weaver/blob/master/examples/structured_output_agent.exs)
checks an order lookup and its structured answer.

Look up the sample order before producing the typed answer. Verify the tool result as well as the final schema:

```elixir
defmodule MyApp.LookupStatus do
  use BeamWeaver.Tool
  name "lookup_status"
  description "Read the delivery status of sample order A-1001."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => "A-1001"}, _opts), do: {:ok, "A-1001 was damaged in transit."}
end

defmodule MyApp.InformedTriage do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Use lookup_status for the order before triaging. Describe the returned status in the summary."
  tools [MyApp.LookupStatus]
  response_schema MyApp.Ticket
end

{:ok, result} = MyApp.InformedTriage.invoke(%{messages: ["Check A-1001 and triage its delivery issue."]})
%{"category" => "shipping", "order_id" => "A-1001", "summary" => summary} = result.structured_response
true = String.downcase(summary) =~ "damaged"
true = Enum.any?(result.messages, &(&1.role == :tool and &1.name == "lookup_status"))
```

## Validation errors and retries

BeamWeaver validates required top-level keys and basic JSON types. It does
not recursively validate nested objects or array items, nor enforce every
constraint such as enum, numeric bounds or patterns. Strict provider schemas
supply additional enforcement. Validate critical business rules yourself.

| Error | Meaning |
| --- | --- |
| `:structured_output_parse_error` | The answer is not valid JSON |
| `:structured_output_validation_error` | Required keys or top-level types do not match |
| `:missing_structured_output` | No schema-tool answer arrived |
| `:multiple_structured_outputs` | Several schema-tool answers arrived |

The tool strategy feeds invalid answers back for up to `max_retries` retries
(default 2). `handle_errors: false` returns the first error; a string or
function customizes feedback. Native output validation errors fail directly.

`BeamWeaver.Agent.Middleware.StructuredOutputRetry` retries failed answers
across strategies. Set `handle_errors: false` to let errors reach it.
Its `max_retries:` defaults to 1; `feedback:` controls the correction prompt.
Budget the total attempts if you combine retry policies. Failed answers and
correction messages remain in saved history.

Select the tool strategy and bound its correction attempts. This real call verifies the configured extraction; malformed-answer tests belong in the Testing guide:

```elixir
defmodule MyApp.ToolStrategyTriage do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Extract the ticket facts. Delivery issues belong to shipping."
  response_schema MyApp.Ticket, strategy: :tool, max_retries: 2
end

{:ok, result} = MyApp.ToolStrategyTriage.invoke(%{messages: ["Where is order A-1001? It has not arrived."]})
%{"category" => "shipping", "order_id" => "A-1001"} = result.structured_response
```

## Without an agent

For one extraction call, use the model interface directly:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000)
format = %{name: "ticket", schema: MyApp.Ticket.json_schema()}

{:ok, reply} =
  BeamWeaver.Core.ChatModel.invoke(
    model,
    "Extract this ticket: Where is order A-1001? Use category shipping.",
    response_format: format
  )

%{"category" => "shipping", "order_id" => "A-1001"} = reply.metadata.parsed
```

Direct calls return provider-decoded output in `metadata.parsed`. They do not
add the agent's strategy selection, validation loop or retry middleware.

## Read the result

Pattern-match mandatory fields, then validate domain constraints. Schema
conformance is a data-format guarantee, not evidence that every fact is
correct. Ground factual answers in the input or successful tool results.

## Test with the fake model

`BeamWeaver.Models.FakeChatModel.final/1` supplies valid or malformed answers
in application tests. [Testing](testing.md) explains scripted responses and
request assertions. Keep a live integration check for the production model.
