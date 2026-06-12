# Structured Output

Structured output lets agents and chat models return predictable data instead
of prose that your application has to parse. In BeamWeaver, structured output is
represented as JSON-shaped Elixir maps validated against JSON Schema-shaped
maps.

Use structured output in two places:

- Stable agent modules use `response_schema/2` with `BeamWeaver.Schema`.
  Runtime-generated agents can use `:response_format`. Both return
  `:structured_response` in the final agent state.
- Chat models use `BeamWeaver.Models.with_structured_output/3` or provider
  `:response_format` options and return parsed data in message metadata.

{% hint style="info" %}
**Agent And Model APIs**

LangChain's Python docs describe structured output through `create_agent` and
model wrappers. BeamWeaver keeps the same separation, but the API is native
Elixir: module agents use `response_schema/2`, runtime agents use
`BeamWeaver.Agent.build/1`, and standalone models use
`BeamWeaver.Models.with_structured_output/3`.
{% endhint %}

## Agent Usage

Define the response shape with `BeamWeaver.Schema` and pass it to
`response_schema/2`.

```elixir
defmodule MyApp.ContactInfo do
  use BeamWeaver.Schema

  title "contact_info"
  description "Contact information for a person."
  strict true

  field :name, :string, required: true, description: "The person's name"
  field :email, :string, required: true, description: "The email address"
  field :phone, :string, required: true, description: "The phone number"
end

defmodule MyApp.ContactAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")
  response_schema MyApp.ContactInfo, name: "contact_info", strategy: :auto
end

{:ok, state} =
  MyApp.ContactAgent.invoke(%{
    messages: [
      BeamWeaver.Core.Message.user(
        "Extract contact info: John Doe, john@example.com, (555) 123-4567"
      )
    ]
  })

state.structured_response
# %{
#   "name" => "John Doe",
#   "email" => "john@example.com",
#   "phone" => "(555) 123-4567"
# }
```

Runtime-built agents use `:response_format` because they are assembled from
runtime data. Given the same schema module:

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Agent.StructuredOutput
alias BeamWeaver.Core.Message

{:ok, agent} =
  Agent.build(
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini"),
    tools: [],
    response_format: StructuredOutput.auto(MyApp.ContactInfo.json_schema())
  )

{:ok, state} =
  Agent.invoke(agent, %{
    messages: [Message.user("Extract contact info from the text.")]
  })

state.structured_response
```

{% hint style="warning" %}
**Python Schema Objects**

LangChain examples use Pydantic models, dataclasses, and `TypedDict` classes
because Python can inspect those objects and turn them into JSON Schema.
BeamWeaver does not accept those Python runtime objects. Elixir structs and
typespecs also do not carry runtime field descriptions, nested constraints, or
validation rules. Use `BeamWeaver.Schema` for stable application modules. Use
JSON Schema maps only for dynamic construction, provider payloads, or migration
compatibility.
{% endhint %}

## Response Formats

BeamWeaver response formats are built with `BeamWeaver.Agent.StructuredOutput`.

| Format | Use |
| --- | --- |
| `StructuredOutput.tool(schema, opts)` | Ask the model to call a synthetic structured-output tool. |
| `StructuredOutput.provider(schema, opts)` | Ask the provider API to enforce structured output natively. |
| `StructuredOutput.auto(schema, opts)` | Auto-select provider strategy when the model profile supports structured output safely, otherwise tool strategy. |
| `nil` | No structured output request. |

Unlike the Python docs, BeamWeaver does not expose generic
`ToolStrategy[SchemaT]` or `ProviderStrategy[SchemaT]` classes. The functions
above return Elixir strategy structs.

In module DSL, the normal form is:

```elixir
response_schema MyApp.ContactInfo,
  name: "contact_info",
  strategy: :auto
```

Strategy values are atoms. Public Elixir config rejects string aliases such as
`"auto"` and `"tool"`; use `:auto`, `:tool`, or `:provider`.

## Provider Strategy

Provider strategy uses the model provider's native structured-output API.
OpenAI, Anthropic, Google, and xAI provider adapters accept structured output
request options, and agent auto-selection uses the model profile's
`:structured_output` capability.

```elixir
response_schema MyApp.ContactInfo,
  name: "contact_info",
  strategy: :provider,
  strict: true
```

`strict: true` is passed to providers that support strict JSON Schema
adherence. Provider support varies; unsupported providers may ignore strictness
or reject the request.

For OpenAI response formats, BeamWeaver normalizes strict schemas before sending
the request: object schemas are closed with `additionalProperties: false`, every
declared property is listed in `required`, optional properties become nullable,
and unsupported validation/composition keywords are removed. A free-form object
such as `%{"type" => "object"}` becomes a closed empty object in strict mode;
model genuinely dynamic key/value payloads as arrays of entries or use
non-strict/application validation when arbitrary keys are required.

Provider-native structured output and active tool calling are not equally
reliable across providers. When normal tools are active, BeamWeaver avoids
provider-native structured output unless the model profile explicitly marks the
combination as supported with `structured_output_with_tools: true`. Otherwise
the effective strategy is the tool strategy, preserving the same schema name.

Structured-output strategy selection is profile-backed. BeamWeaver evaluates:

- `structured_output`
- `structured_output_with_tools`
- `structured_output_max_schema_bytes`
- `structured_output_max_schema_properties`

Strategy behavior is deterministic:

- `:tool` always uses the structured-output tool strategy.
- `:provider` uses provider-native structured output only when the model
  profile says it is safe; otherwise it falls back to tool strategy and records
  the fallback reason in trace metadata.
- `:auto` chooses provider-native only when the profile supports it, active
  tools are safe, and schema size/property limits pass; otherwise it chooses
  tool strategy.

Trace metadata includes:

- `structured_output_requested_strategy`
- `structured_output_effective_strategy`
- `structured_output_fallback_reason`
- `structured_output_schema_bytes`
- `structured_output_schema_properties`

For specialists that need tools and must return structured data, prefer a
research pass followed by a tool-free structured generation pass. In agent
modules this is configured with `execution_mode: :research_then_generate`.

Raw JSON Schema maps are compatibility and dynamic-construction inputs. For
example, a runtime builder can receive a schema map from configuration and wrap
it explicitly:

```elixir
response_format StructuredOutput.auto(@contact_schema)
```

{% hint style="info" %}
**Model Profiles**

Python LangChain can read native structured-output support dynamically from
model profile data. BeamWeaver uses its local model profile registry and any
explicit `:profile` override you pass to `init_chat_model/2`. If a future model
supports provider-native structured output before BeamWeaver's checked-in
profile data knows about it, pass a profile override with
`structured_output: true`. Only add `structured_output_with_tools: true` after
you have verified that the provider/model combination can reliably mix native
structured output and tool calls.
{% endhint %}

Provider strategy returns the parsed structured value in `state.structured_response`:

```elixir
{:ok, state} =
  MyApp.ProviderAgent.invoke(%{
    messages: [BeamWeaver.Core.Message.user("Extract the contact info.")]
  })

state.structured_response
```

## Tool Strategy

Tool strategy works with models that support tool calling. BeamWeaver registers
a synthetic tool whose name comes from the schema `title`.

```elixir
defmodule MyApp.ProductReview do
  use BeamWeaver.Schema

  title "product_review"
  description "Analysis of a product review."
  strict true

  field :rating, {:nullable, :integer}, description: "Rating from 1 to 5"
  field :sentiment, :string, required: true, enum: ["positive", "negative"]
  field :key_points, {:array, :string}, required: true
end

response_schema MyApp.ProductReview,
  name: "product_review",
  strategy: :tool
```

When the model calls the synthetic tool, BeamWeaver validates the tool
arguments, stores the parsed map in `:structured_response`, and adds a
`tool` message to the conversation history:

```elixir
%{
  structured_response: %{
    "rating" => 5,
    "sentiment" => "positive",
    "key_points" => ["fast shipping", "expensive"]
  },
  messages: messages
}
```

When normal tools are present alongside the structured-output tool, ordinary
tool calls continue the agent loop. The run ends with `:structured_response`
only after the model calls one of the structured-output pseudo tools. BeamWeaver
marks those pseudo tools with structured-output metadata for tracing and asks
providers to choose a tool when the tool strategy is active.

Customize the tool message content when you want the model-visible observation
to be stable and short:

```elixir
response_schema MyApp.ReviewSchema,
  name: "product_review",
  strategy: :tool,
  tool_message_content: "Structured review captured."
```

{% hint style="warning" %}
**Validation Scope**

Provider-native structured output can enforce more of the JSON Schema when the
provider supports it. BeamWeaver's local validation currently checks that the
structured response is an object, required keys are present, and property values
match basic JSON types. Constraints such as `enum`, `minimum`, `maximum`, regex
patterns, and cross-field domain rules should be enforced by the provider or by
application validation after reading `state.structured_response`.
{% endhint %}

## Multiple Schema Choices

For tool strategy, use `oneOf` to let the model choose one structured-output
shape. BeamWeaver creates one synthetic tool per variant.

```elixir
@schema %{
  "oneOf" => [
    %{
      "title" => "contact_info",
      "type" => "object",
      "required" => ["name", "email"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "email" => %{"type" => "string"}
      }
    },
    %{
      "title" => "event_details",
      "type" => "object",
      "required" => ["event_name", "date"],
      "properties" => %{
        "event_name" => %{"type" => "string"},
        "date" => %{"type" => "string"}
      }
    }
  ]
}

response_schema @schema, name: "contact_or_event", strategy: :tool
```

If the model calls more than one structured-output tool for a single response,
BeamWeaver returns a `:multiple_structured_outputs` error or creates an error
tool message, depending on the `:handle_errors` setting.

## Error Handling

Tool strategy accepts `:handle_errors`:

```elixir
response_schema MyApp.ReviewSchema,
  name: "product_review",
  strategy: :tool,
  handle_errors: true
```

Supported values:

| Value | Behavior |
| --- | --- |
| `true` | Convert structured-output errors into tool messages. |
| `false` | Return the tagged error to the caller or middleware. |
| `"message"` | Use this message as the error tool message. |
| `:structured_output_validation_error` | Handle only this tagged error type. |
| `[:structured_output_validation_error, :multiple_structured_outputs]` | Handle only these tagged error types. |
| `fn error -> message end` | Build a custom message from `%BeamWeaver.Core.Error{}`. |

{% hint style="info" %}
**Tagged Errors, Not Python Exceptions**

Python LangChain lets `handle_errors` refer to exception classes. BeamWeaver
does not expose Python exception classes. Recoverable failures are tagged
`%BeamWeaver.Core.Error{}` values such as
`:structured_output_validation_error`, `:structured_output_parse_error`, and
`:multiple_structured_outputs`.
{% endhint %}

To make the model retry after validation failures, add
`BeamWeaver.Agent.Middleware.StructuredOutputRetry` and let structured-output
errors propagate from the strategy:

```elixir
defmodule MyApp.RetryingReviewAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.StructuredOutputRetry
  alias BeamWeaver.Agent.StructuredOutput

  @review_schema %{
    "title" => "product_review",
    "type" => "object",
    "required" => ["sentiment"],
    "properties" => %{
      "sentiment" => %{"type" => "string"},
      "key_points" => %{"type" => "array"}
    }
  }

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")

  middleware do
    use StructuredOutputRetry, max_retries: 2
  end

  response_schema @review_schema,
    name: "product_review",
    strategy: :tool,
    handle_errors: false
end
```

Customize retry feedback with a fixed message or function:

```elixir
middleware do
  use StructuredOutputRetry,
    max_retries: 2,
    feedback: fn error -> "Fix the structured output: #{error.message}" end
end
```

## Direct Model Usage

Use `BeamWeaver.Models.with_structured_output/3` when you want structured
output from a standalone chat model without an agent loop.

```elixir
alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.Models

contact_schema = %{
  "title" => "contact_info",
  "type" => "object",
  "required" => ["name", "email"],
  "properties" => %{
    "name" => %{"type" => "string"},
    "email" => %{"type" => "string"}
  }
}

model =
  BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")
  |> Models.with_structured_output(contact_schema)

{:ok, response} =
  ChatModel.invoke(model, [
    Message.user("Extract contact info: John Doe, john@example.com")
  ])

response.metadata.structured_response
```

Provider adapters also accept direct structured-output options:

```elixir
{:ok, response} =
  ChatModel.invoke(model, [Message.user("Return JSON for this contact.")],
    response_format: %{
      name: "contact_info",
      schema: contact_schema,
      strict: true
    }
  )

response.metadata["parsed"]
```

OpenAI and xAI Responses and Chat Completions use JSON Schema response formats.
Anthropic uses `output_config.format` for structured output. Google maps
schemas to Gemini generation config. Structured-output parse errors include the
provider finish/status reason, clipped content preview, metadata, and usage
details so truncation and tool-call-only responses can be diagnosed without
logging the full provider payload. See the [OpenAI](partners/openai.md),
[Anthropic](partners/anthropic.md), [Google](partners/google.md), [xAI](partners/xai.md), and [Models](models.md)
guides for provider-specific request details.

## Related

- [Agents](agents.md)
- [Models](models.md)
- [Tools](tools.md)
- [Messages](messages.md)
- [Middleware](middleware.md)
- [Custom Middleware](custom_middleware.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Guardrails](guardrails.md)
- [Context Engineering](context_engineering.md)
