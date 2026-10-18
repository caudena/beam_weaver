# Models and Provider Calls

Use an agent when the model should select and execute tools. Call a chat model
directly for a single completion, extraction or classification. Both paths
use the same provider adapters and message types.

Complete [Installation](installation.md) and configure OpenAI before running
this page's examples in order.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Call a model

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000)
{:ok, reply} = ChatModel.invoke(model, "Explain what an order tracking number is in one sentence.")
text = Message.text(reply)
true = byte_size(text) > 0
IO.puts(text)
```

Initialization validates the identifier and options; **the invocation makes
the network request**. Successful construction does not verify credentials,
model access or account balance. `init_chat_model!/2` raises on construction
errors; the non-bang version returns an error tuple.

## Name a model

Always use `provider:model`. Chat providers are OpenAI, Anthropic, Google,
xAI, DeepSeek, Moonshot and Z.ai. TypeSafe supplies decision models, not a
chat backend. See [Providers](providers.md) for supported operations.

```bash
mix beam_weaver.models.profiles
mix beam_weaver.models.profiles --provider google
```

This lists checked-in profiles, not your account's live entitlements. A few
bare prefixes can be inferred, but explicit provider names avoid ambiguity.
An identifier's presence in a profile does not grant access to that model.

## Create a model

Choose constructor options when you initialize a model. Supply request-only
options such as `tools:` and `tool_choice:` on the call. Unknown or unsupported
options produce errors rather than silently disappearing.

| Option | Purpose |
| --- | --- |
| `api_key:` | Override application credentials for this instance |
| `max_tokens:`, `max_output_tokens:` | Bound generated tokens |
| `timeout:` | Provider request timeout in milliseconds; default 15,000 |
| `temperature:`, `top_p:` | Sampling controls where the model supports them |
| `stream:` | Request incremental output when used by an agent |
| `extra_body:` | Additional native request fields; the provider still validates them |
| `profile:` | Explicit capability/limit metadata for this instance |

Options differ by model as well as provider. Check the provider guide before
combining reasoning controls, sampling controls and output limits.

## Models in agents

An agent accepts a model identifier or a constructed model. Declaration
options are applied to model calls. Per-run `model_opts:` overrides let you
adjust a request without defining another agent:

```elixir
defmodule MyApp.BriefAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Give concise explanations."
end

{:ok, result} =
  MyApp.BriefAgent.invoke(%{messages: ["What is a tracking number?"]},
    model_opts: [max_tokens: 128]
  )

true = byte_size(result.messages |> List.last() |> Message.text()) > 0
```

The model's `timeout:` also bounds the agent's model step. A whole run can
contain several calls, so use `run_timeout` for its total budget.

### Defaults for agent models

`BeamWeaver.Agent.ProviderProfile` registers application-wide defaults by
provider or model. Register them once during application startup. Model-level
defaults override provider defaults, and declaration options override both.
They apply to agent model identifiers; directly constructed models do not
inherit them. Register defaults before starting work, as in the example below.

Register application defaults once at startup, then run an agent that inherits them. Explicit declarations still win:

```elixir
alias BeamWeaver.Agent.ProviderProfile

:ok =
  ProviderProfile.register_provider_profile(
    "openai:gpt-5.4-mini",
    ProviderProfile.new(init_kwargs: [max_tokens: 128, timeout: 60_000])
  )

defmodule MyApp.DefaultedAgent do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini"
  system_prompt "Answer briefly."
end

{:ok, result} = MyApp.DefaultedAgent.invoke(%{messages: ["Say hello."]})
true = byte_size(BeamWeaver.Core.Message.text(List.last(result.messages))) > 0
```

### Images and PDFs

Agents adapt requests when built-in model profiles say images or PDFs are
unsupported: the request contains an omission notice while saved history
retains the original media. This allows a later compatible model to read it.
The adaptation follows fallback selection. Explicit custom profiles and
unknown profiles do not receive that automatic omission policy.

Direct model calls validate their own supported inputs. Use
[Messages](messages.md) and the provider guide for actual media formats.

## Batch and concurrency

`ChatModel.batch/3` returns one result per input in input order. For explicit
parallelism, use `Task.async_stream/3` and choose a concurrency limit compatible
with your provider's quota:

```elixir
results =
  ["Define a parcel in one sentence.", "Define a tracking number in one sentence."]
  |> Task.async_stream(&ChatModel.invoke(model, &1), max_concurrency: 2, timeout: 70_000)
  |> Enum.map(fn {:ok, {:ok, message}} -> Message.text(message) end)

2 = length(results)
true = Enum.all?(results, &(byte_size(&1) > 0))
```

In production, also handle task exits and individual model errors. A task
timeout and a provider request timeout are separate limits.

## Stream a reply

```elixir
{:ok, stream} = ChatModel.stream_typed_events(model, "Explain tracking numbers briefly.")
events = Enum.to_list(stream)
false = Enum.any?(events, &match?(%{event: %BeamWeaver.Stream.Events.Error{}}, &1))
text = for %{event: %BeamWeaver.Stream.Events.Token{text: text}} <- events, into: "", do: text
true = byte_size(text) > 0
```

Consume the stream to execute it. Retain the collected events if you need to
inspect them more than once. Do not assume a constructed stream is evidence
of a successful request. [Streaming](streaming.md) explains ownership,
cancellation, partial failures and UI integration.

## Errors

Calls return `{:error, %BeamWeaver.Core.Error{}}` on failure. Inspect `type`
for application handling and `details` for provider status, code and
retryability. A live stream can fail after returning `{:ok, stream}`; its
terminal `Error` event carries the failure.

| Type | Typical response |
| --- | --- |
| `:authentication`, `:permission_denied` | Correct credentials or access |
| `:not_found`, `:invalid_request`, `:unsupported_model_param` | Correct model or request options |
| `:rate_limit`, `:server_error`, `:connection`, `:timeout` | Retry only within a bounded policy |
| `:context_overflow` | Reduce or compact the input |
| `:billing_exhausted` | Resolve the account's billing or usage limit |
| `:content_filter` | Handle the rejected request without an automatic identical retry |
| `:transport_error`, `:http_error` | Inspect transport/status details |

Provider adapters do not independently retry calls. Add `ModelRetry` to an
agent or implement a bounded direct-call policy. `ModelFallback` can choose
another model after failure. With fallback outside retry, each model gets
its own retry budget; see [Built-in Middleware](builtin_middleware.md).

Some APIs signal failure in a stream event or finish reason rather than an
HTTP error. BeamWeaver normalizes documented inference failures. A normal
length-limited reply is still a reply: inspect its status and completeness.
Never infer success from HTTP status alone.

## Reasoning

Reasoning configuration is provider-specific:

| Provider | Controls |
| --- | --- |
| OpenAI, xAI | `reasoning_effort:` or a `reasoning:` map, where supported |
| Anthropic | `thinking:` and `reasoning_effort:` / `effort:` |
| Google | `thinking_level:` or `thinking_budget:`, plus `include_thoughts:` |
| DeepSeek, Z.ai | `thinking:` and model-supported reasoning effort |
| Moonshot | `thinking:` for Kimi K2; reasoning effort for Kimi K3 |

Profiles expose accepted effort levels and defaults. Returned reasoning, when
provided, uses content blocks; do not assume every provider returns it or
that it is suitable for display to end users.

Reasoning controls belong on a model that accepts them; invoke it to verify the request:

```elixir
{:ok, reasoning_model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", reasoning_effort: :low)
{:ok, reasoning_reply} = BeamWeaver.Core.ChatModel.invoke(reasoning_model, "What is 2 + 2?")
true = byte_size(BeamWeaver.Core.Message.text(reasoning_reply)) > 0
```

## Model profiles

Profiles describe context/output limits and capabilities, including tools,
structured output, streaming and media. They are local compatibility data:

```elixir
true = BeamWeaver.Provider.Compatibility.supports?(model, :tool_calling)
true = model.profile.max_input_tokens > 0
```

Use `BeamWeaver.Provider.Compatibility.features/0` for valid feature names.
Calls validate model parameters and requested capabilities against the
profile. Unknown identifiers may receive family defaults or be rejected,
depending on the provider. Do not invent a model ID to bypass validation.

A `profile:` override changes local metadata, not provider capabilities or
account access. Start from the existing profile and override only facts you
have established about your deployment.

## Embeddings

Embedding models map text to vectors for retrieval. Use a real embedding
model when assessing search quality:

```elixir
{:ok, embeddings} = BeamWeaver.Models.init_embeddings("openai:text-embedding-3-small")

{:ok, vectors} =
  BeamWeaver.Core.EmbeddingModel.embed_documents(
    embeddings,
    ["Refunds take five days.", "Orders ship in two days."]
  )

{:ok, query} = BeamWeaver.Core.EmbeddingModel.embed_query(embeddings, "When will my refund arrive?")
2 = length(vectors)
true = length(query) > 0
true = Enum.all?(vectors, &(length(&1) == length(query)))
```

Keep the same embedding model and dimensions for stored documents and queries.
[Retrieval](retrieval.md) covers indexing and search; provider guides list
available embedding integrations.

## Token usage

Provider replies carry `usage_metadata`: input, output and total tokens,
plus cache/reasoning details when available. Counts describe actual reported
usage, not a prediction of the next call.

```elixir
true = reply.usage_metadata.total_tokens > 0
usage = BeamWeaver.Agent.Usage.from_messages(result.messages)
true = usage.model_calls > 0
```

`BeamWeaver.Models.UsageCost.calculate/3` estimates cost using profile prices.
Actual billing depends on provider pricing and account terms. [Tracing](tracing.md)
records per-call usage and attribution.

## Decision models

Decision models answer typed questions instead of generating chat text.
`init_decision_model/2` supports the OpenAI and TypeSafe integrations.
`BeamWeaver.Core.DecisionModel` supplies question constructors, `choose/4` and
`probability/4`; handle refusal as well as successful answers and errors.
Use the complete [OpenAI](providers/openai.md#decisions) or
[TypeSafe](providers/typesafe.md) example for its native question contract.

A decision model returns a typed probability rather than a chat sentence:

```elixir
alias BeamWeaver.Core.DecisionModel

{:ok, model} = BeamWeaver.Models.init_decision_model("openai:gpt-6-luna")
{:ok, question} = DecisionModel.yes_no_question(model, "Does the customer ask for a refund?")

case DecisionModel.probability(model, "I want my money back for order A-1001.", question) do
  {:ok, probability, _response} when probability >= 0.8 -> :refund_request
  {:ok, _probability, _response} -> :other
  {:refused, _response} -> :unclear
  {:error, error} -> {:error, error}
end
```

## API keys

Load credentials into **your application's** runtime configuration. A library's
own `config/runtime.exs` is not loaded by a consumer. Each provider reads its
application group, such as `config :beam_weaver, :openai, api_key: ...`.
[Configuration](configuration.md) covers precedence and deployment setup.

## Fake models

Fake chat and embedding models belong in deterministic application tests.
Fake embeddings carry no semantic meaning. [Testing](testing.md) explains
scripts, request assertions and replay; use live integrations to validate
actual provider behavior.
