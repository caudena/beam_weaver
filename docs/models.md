# BeamWeaver Models

Models are the reasoning engines used directly by applications and by
BeamWeaver agents. BeamWeaver follows the LangChain model behavior where it is
useful, but the public API is Elixir-native: structs, behaviours, keyword
options, Task-backed async helpers, `Enumerable` streams, typed stream envelopes,
telemetry, and tagged errors.

Use Python model docs as behavioral examples, not as package or callback API
requirements.

## Basic Usage

Models can be used in two places:

- with agents, where the agent loop decides when to call the model and tools
- standalone, where application code calls the model directly

The same `%BeamWeaver.Core.Message{}` values work in both places.

## Initialize A Model

Provider secrets and endpoint defaults are application config. A typical
`config/runtime.exs` loads them from the OS environment once:

```elixir
import Config

config :beam_weaver,
  openai: [api_key: System.fetch_env!("OPENAI_API_KEY")],
  anthropic: [api_key: System.fetch_env!("ANTHROPIC_API_KEY")],
  xai: [api_key: System.fetch_env!("XAI_API_KEY")],
  google: [api_key: System.fetch_env!("GOOGLE_API_KEY")]
```

`BeamWeaver.Models.init_chat_model/2` accepts provider-prefixed identifiers.
Unprefixed `gpt-*` and `o*` names infer OpenAI. Unprefixed `claude-*` names infer
Anthropic. Unprefixed `grok-*` names infer xAI. Gemini models must use the
explicit `google:` prefix.

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("openai:gpt-5.4",
    temperature: 0.2,
    timeout: 30_000
  )
```

Anthropic:

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("anthropic:claude-sonnet-4-5",
    max_tokens: 1_000
  )
```

xAI:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("xai:grok-4.3")
```

Google:

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("google:gemini-3.5-flash",
    thinking_budget: 512
  )
```

Fake model for tests:

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("fake:chat",
    response: BeamWeaver.Core.Message.assistant("fixture response")
  )
```

Provider structs are available when you want direct control:

```elixir
model =
  BeamWeaver.OpenAI.ChatModel.new(
    model: "gpt-5.4",
    reasoning_effort: :low,
    timeout: 30_000
  )
```

OpenAI defaults to the Responses API. Use Chat Completions explicitly when that
API shape is required:

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini",
    api: :chat_completions
  )
```

## Supported Providers And Models

Provider scope is intentionally narrow:

- `BeamWeaver.OpenAI.ChatModel` for OpenAI Responses API
- `BeamWeaver.OpenAI.ChatCompletionsModel` for OpenAI Chat Completions
- `BeamWeaver.OpenAI.EmbeddingModel` for OpenAI embeddings
- `BeamWeaver.Anthropic.ChatModel` for Anthropic Messages API
- `BeamWeaver.Google.ChatModel` for Gemini Developer API
- `BeamWeaver.Moonshot.ChatModel` for Moonshot/Kimi Chat Completions
- `BeamWeaver.XAI.ChatModel` for xAI Responses API
- `BeamWeaver.XAI.ChatCompletionsModel` for xAI Chat Completions
- `BeamWeaver.XAI.EmbeddingModel` for xAI embeddings
- `BeamWeaver.Models.FakeChatModel` and `FakeEmbeddingModel` for tests

Checked-in model profiles cover common OpenAI, Anthropic, Google Gemini,
Moonshot/Kimi, and xAI families. Moonshot chat uses `moonshot:kimi-k2.6`. xAI
chat defaults to `grok-4.3`; current checked-in xAI profiles also
include `grok-4.20-0309-reasoning`, `grok-4.20-0309-non-reasoning`,
`grok-4.20-multi-agent-0309`, `grok-build-0.1`, and embedding model `v1`.
Future OpenAI `gpt-*`/`o*`, Anthropic `claude-*`, explicit Google
`google:gemini-*`, explicit Moonshot `moonshot:kimi-*`, and xAI `grok-*`
identifiers use permissive fallback profiles unless they are known
deprecated/unsupported slugs. Bare `gemini-*` and `kimi-*` IDs are rejected so
provider routing is explicit.

{% hint style="warning" %}
**Provider Scope**

LangChain can expose many providers through separate Python integration
packages. BeamWeaver only documents a provider after it has a native transport
boundary, message translator, model profile behavior, fake/replay tests, and
provider-specific option handling. That work exists for OpenAI, Anthropic,
Google Gemini, Moonshot/Kimi, xAI, and fake models. Azure OpenAI, Vertex AI,
Bedrock, HuggingFace, OpenRouter/LiteLLM, Ollama, and local model runtimes need
dedicated BeamWeaver adapters before they can be treated as supported providers.

OpenAI-compatible HTTP routers can sometimes be reached with an explicit
`:endpoint`, but that only changes the URL. It does not add router-specific
request fields, response metadata, pricing metadata, or block translation.
{% endhint %}

## Harness-Oriented Model Suggestions

The official Deep Agents models page says Deep Agents can use any LangChain chat
model with tool calling, then lists models that performed well on LangChain's
Deep Agents eval suite. BeamWeaver does not run or publish that eval matrix, so
the table from the official page is not copied here as BeamWeaver benchmark
data.

Treat the following as LangChain's external guidance for Deep Agents-style
harnesses, not as a BeamWeaver certification list:

| Provider family | Suggested models from LangChain |
|---|---|
| Google | `gemini-3.1-pro-preview`, `gemini-3.5-flash` |
| OpenAI | `gpt-5.5`, `gpt-5.5-pro`, `gpt-5.4`, `gpt-5.4-pro`, `gpt-5.4-mini`, `gpt-5.4-nano`, `gpt-5`, `gpt-5-mini`, `gpt-5-nano`, `gpt-4.1` |
| Anthropic | `claude-opus-4-7`, `claude-opus-4-6`, `claude-opus-4-5`, `claude-opus-4-5-20251101`, `claude-opus-4-1-20250805`, `claude-sonnet-4-6`, `claude-sonnet-4-5`, `claude-haiku-4-5` |
| Open-weight or routed | `GLM-5`, `Kimi-K2.5`, `MiniMax-M2.5`, `qwen3.5-397B-A17B`, `devstral-2-123B` |

The OpenAI, Anthropic, and Google families in that list currently overlap with
native BeamWeaver provider adapters. Use `google:gemini-*` for Gemini Developer
API models. Baseten, Fireworks, OpenRouter, Ollama, and other routed or
open-weight providers need dedicated BeamWeaver adapters before their
`provider:model` strings should be documented as supported BeamWeaver
identifiers.

For BeamWeaver-specific harness support, use the
[Deep Agents model matrix](partners.md#deep-agents-model-matrix). That table
maps supported BeamWeaver model strings to the agent capabilities that matter
for planning, tools, virtual filesystems, subagents, structured output,
streaming, and token-budget management.

{% hint style="warning" %}
**No BeamWeaver Eval Matrix**

LangChain's Deep Agents eval suite is useful external signal for special
harness behavior such as file operations, tool use, memory, conversation, and
summarization. BeamWeaver has local unit and docs coverage for its harness
middleware, but it does not currently publish comparable cross-model eval
scores. Use the LangChain suggestions to choose candidate models, then validate
them against your own BeamWeaver tasks and providers.
{% endhint %}

## Key Methods

Use the behaviour modules as the stable call boundary:

- `BeamWeaver.Core.ChatModel.invoke/3`
- `BeamWeaver.Core.ChatModel.stream/3`
- `BeamWeaver.Core.ChatModel.stream_events/3`
- `BeamWeaver.Core.ChatModel.batch/3`
- `BeamWeaver.Core.ChatModel.async_invoke/3`
- `BeamWeaver.Core.ChatModel.async_batch/3`
- `BeamWeaver.Core.EmbeddingModel.embed_documents/3`
- `BeamWeaver.Core.EmbeddingModel.embed_query/3`

Provider modules may expose additional provider-specific helpers, such as
`stream_response/3`, `count_tokens/3`, and deferred request helpers.

{% hint style="info" %}
**Chat Models And Legacy LLMs**

LangChain's Python docs distinguish chat models, which return message objects,
from older text-completion LLMs, which return strings. BeamWeaver's provider
surface is centered on chat/message APIs because OpenAI Responses, OpenAI Chat
Completions, Anthropic Messages, Gemini Developer API, and xAI chat APIs all
carry roles, tool calls, multimodal blocks, usage metadata, and provider
metadata. Test-only LLM fakes and the core behaviour may exist for conformance
work, but provider text-completion wrappers are not a public workflow.
{% endhint %}

## Parameters

Common chat model options include:

| Option | Meaning |
|---|---|
| `:model` | provider model identifier |
| `:api_key` | provider API key, usually from environment |
| `:temperature` | sampling temperature where supported |
| `:max_tokens`, `:max_output_tokens` | output token limit |
| `:timeout` | transport receive timeout in milliseconds |
| `:top_p`, `:frequency_penalty`, `:presence_penalty`, `:seed` | standard sampling controls |
| `:tools`, `:tool_choice`, `:parallel_tool_calls` | tool calling controls |
| `:response_format`, `:structured_output` | structured output controls |
| `:metadata`, `:user`, `:service_tier` | provider request metadata |
| `:model_kwargs`, `:extra_body` | explicit provider escape hatches |
| `:transport`, `:transport_opts` | transport boundary for live, fake, or replay calls |
| `:profile`, `:profile_registry`, `:param_policy` | capability metadata and validation |

Provider constructors use native option names. Use `:model`, not `:model_name`.
Use `:endpoint` or a custom transport for exact routing. The xAI constructors
also accept `:base_url` as an upstream alias.

{% hint style="info" %}
**Option Names**

LangChain examples often use Python client aliases such as `model_name`,
`base_url`, or `openai_proxy`. BeamWeaver keeps most provider structs explicit:
`:model` names the model, `:endpoint` names the HTTP endpoint, and proxy or
replay behavior belongs at the `BeamWeaver.Transport` boundary. xAI keeps
`:base_url` for compatibility with that constructor alias.
{% endhint %}

Known profiles default to strict parameter validation. Unknown future profiles
are permissive so new model names can work before profile data catches up.

## Provider Profiles

`BeamWeaver.Agent.ProviderProfile` packages model-construction defaults for
agent model strings. It is the BeamWeaver equivalent of Deep Agents provider
profiles, scoped to `BeamWeaver.Agent.build/1` and the `use BeamWeaver.Agent`
capability pipeline.

Provider profiles apply when the agent receives a binary or atom model
identifier:

```elixir
alias BeamWeaver.Agent.ProviderProfile

:ok =
  ProviderProfile.register_provider_profile(
    "openai",
    ProviderProfile.new(init_kwargs: [temperature: 0])
  )

:ok =
  ProviderProfile.register_provider_profile(
    "openai:gpt-5.4",
    ProviderProfile.new(init_kwargs: [reasoning_effort: :medium])
  )

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4",
    tools: []
  )
```

Provider-level profiles such as `"openai"` apply to every model for that
provider. Model-level profiles such as `"openai:gpt-5.4"` merge on top of the
provider-level profile. Caller options still win over profile defaults.

BeamWeaver includes a built-in `"openai"` provider profile that sets
`use_responses_api: true` for agent model strings. Passing a preconfigured model
struct bypasses provider profile initialization because the model has already
been built:

```elixir
model =
  BeamWeaver.Models.init_chat_model!("openai:gpt-5.4",
    temperature: 0.2
  )

{:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [])
```

{% hint style="info" %}
**Provider Profiles Versus Capability Profiles**

Provider profiles shape how a model string is initialized. Model profiles
describe provider capabilities such as context window, tool calling, structured
output, and streaming. Agent capability profiles describe harness defaults such
as tools, middleware, and excluded features. Keep these separate when porting
Deep Agents examples. See [Profiles](profiles.md) for the full comparison.
{% endhint %}

## Connection Resilience

BeamWeaver does not automatically retry every provider request six times the way
LangChain does. The live Req/Finch transport disables implicit retries. In
agents, attach retry and fallback policies as middleware:

```elixir
defmodule MyApp.Agent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4",
          timeout: 120_000
        )

  middleware [
    {BeamWeaver.Agent.Middleware.ModelRetry,
     policy: [
       max_attempts: 4,
       initial_delay: 250,
       retry_on: :transient
     ]}
  ]
end
```

Useful `retry_on` values include `:error`, `:all`, an error type atom, a list of
error type atoms, a one-argument predicate, `{module, function, extra_args}`, or
`:transient`. The `:transient` predicate covers common provider and transport
failures such as timeouts, closed connections, HTTP 408/429/5xx responses,
overload, and rate-limit errors.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ModelFallback,
   fallbacks: [backup_model],
   retry_on: [:rate_limit, :timeout, :transport_error]}
]
```

Retry and fallback policies are intentionally middleware-only. Keep provider
model values simple; compose resilience at the agent boundary where tracing,
call limits, interrupts, context editing, and tool middleware share the same
runtime.

Use checkpointers for long-running agents and graphs so application progress is
not tied to one provider request.

## Invocation

Invoke with a string:

```elixir
alias BeamWeaver.Core.ChatModel

{:ok, message} = ChatModel.invoke(model, "Explain OTP supervision in one paragraph.")
IO.puts(BeamWeaver.Core.Message.text(message))
```

Invoke with message history:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

messages = [
  Message.system("You translate English to French."),
  Message.user("Translate: I enjoy building applications.")
]

{:ok, response} = ChatModel.invoke(model, messages)
```

Maps and `{role, content}` tuples can be normalized by `MessageLike`, but new
code should prefer `%BeamWeaver.Core.Message{}` constructors.

## Streaming

`stream/3` returns an `Enumerable` of provider text deltas for scoped live
providers. OpenAI, Anthropic, Google, and xAI live transports emit chunks as the
provider sends them; replay transports emit deterministic chunks from the saved
stream body for tests. Use `stream_events/3` when you need provider semantic
events such as tool-call chunks, reasoning, usage, or lifecycle metadata.

```elixir
{:ok, deltas} = BeamWeaver.Core.ChatModel.stream(model, "Draft a short release note.")
Enum.each(deltas, &IO.write/1)
```

Semantic events:

```elixir
{:ok, events} =
  BeamWeaver.Core.ChatModel.stream_events(model, "Show the reasoning outline.",
    run_id: "run-123"
  )

for event <- events do
  case event do
    %BeamWeaver.Stream.Envelope{event: %{text: text}} ->
      IO.write(text)

    %{"event" => event_name} ->
      IO.inspect(event_name, label: "provider event")

    _other ->
      :ok
  end
end
```

OpenAI, Anthropic, Google, and xAI provider modules also expose
`stream_response/3` when a caller wants the reconstructed final assistant message
from a streamed call.
Provider HTTP errors returned before any successful stream body are represented
as stream error events when consuming a lazy stream.

{% hint style="info" %}
**Streaming Is Explicit**

LangChain can auto-stream through its callback manager when a larger runnable
or graph is streaming. BeamWeaver does not have callback-manager objects.
Streams are explicit `Enumerable` values and typed envelopes, so call
`stream/3` for standalone model text deltas, or `stream_events/3` on models,
agents, and compiled graphs where you want semantic event envelopes.
{% endhint %}

For agent and graph event projections, see [Event Streaming](event_streaming.md).

## Batch

`batch/3` returns ordered tagged results:

```elixir
results =
  BeamWeaver.Core.ChatModel.batch(model, [
    "Summarize the deployment plan.",
    "List the migration risks."
  ])
```

For concurrent work, use Task-backed helpers:

```elixir
tasks =
  BeamWeaver.Core.ChatModel.async_batch(model, [
    [BeamWeaver.Core.Message.user("Summarize the deployment plan.")],
    [BeamWeaver.Core.Message.user("List the migration risks.")]
  ])

results = BeamWeaver.Core.Async.await_batch(tasks, 30_000)
```

{% hint style="info" %}
**Batch Concurrency**

LangChain's model docs expose `batch_as_completed()` and `max_concurrency`
through `RunnableConfig`. BeamWeaver uses the BEAM's normal concurrency tools
instead: `Task`, `Task.Supervisor`, `Enumerable` streams, explicit
backpressure, and rate limiters. This keeps cancellation, supervision, and
resource limits visible in your application tree instead of hiding them in a
Python-style config dictionary.
{% endhint %}

## Tool Calling

Bind user-defined tools to a standalone model with `BeamWeaver.Models.bind_tools/3`:

```elixir
tool =
  BeamWeaver.Core.Tool.from_function!(
    name: "get_weather",
    description: "Get weather for a location.",
    input_schema: %{
      "type" => "object",
      "required" => ["location"],
      "properties" => %{"location" => %{"type" => "string"}}
    },
    handler: fn %{"location" => location}, _opts ->
      {:ok, "Weather for #{location}: clear"}
    end
  )

model_with_tools =
  BeamWeaver.Models.bind_tools(model, [tool],
    tool_choice: :auto,
    parallel_tool_calls: true
  )

{:ok, message} =
  BeamWeaver.Core.ChatModel.invoke(model_with_tools, "Check the weather for Paris.")

for call <- message.tool_calls do
  {:ok, tool_message} = BeamWeaver.Core.Tool.invoke(tool, call)
  # Send tool_message back in the next model turn, or let an agent run the loop.
end
```

Standalone model calls only request tool execution. Agents handle the tool
execution loop automatically.

Server-side provider tools are provider request values:

```elixir
tools = [
  BeamWeaver.OpenAI.ToolCalling.web_search(),
  BeamWeaver.OpenAI.ToolCalling.code_interpreter(%{type: :auto})
]

BeamWeaver.Core.ChatModel.invoke(model, "Find one current release note.", tools: tools)
```

Anthropic server tools are available through `BeamWeaver.Anthropic.Tools`.
Google server tools are available through `BeamWeaver.Google.Tools`.
xAI server tools are available through `BeamWeaver.XAI.Tools`.

## Structured Output

BeamWeaver accepts JSON Schema maps and optional Elixir validator/parser
functions. See [Structured Output](structured_output.md) for agent response
formats, tool strategy, provider strategy, and retry behavior.

{% hint style="warning" %}
**Python Schema Note**

LangChain examples often use Pydantic models or `TypedDict` classes because
Python can introspect those runtime objects and convert them into JSON Schema.
Elixir structs and typespecs are not runtime validation schemas in the same
way: typespecs are primarily static documentation/analysis metadata, and
plain structs do not carry field validation, descriptions, or nested JSON
Schema rules. BeamWeaver therefore takes JSON Schema maps directly and lets you
attach Elixir parser or validator functions when you need runtime validation.
{% endhint %}

```elixir
schema = %{
  "title" => "Project",
  "type" => "object",
  "required" => ["name", "status"],
  "properties" => %{
    "name" => %{"type" => "string"},
    "status" => %{"type" => "string"}
  }
}

structured_model =
  BeamWeaver.Models.with_structured_output(model, schema)

{:ok, response} =
  BeamWeaver.Core.ChatModel.invoke(structured_model, "Extract project name and status.")

response.metadata.structured_response
```

Provider-native structured output is selected when the model profile advertises
support. Otherwise BeamWeaver can fall back to tool-strategy behavior.

For direct provider calls, OpenAI, Anthropic, Google, and xAI also accept
`:response_format`/`:structured_output` options shaped as JSON Schema data.

## Model Profiles

Profiles describe model capabilities such as context window, tool support,
structured output, streaming, reasoning, usage metadata, modalities, tokenizer,
and supported parameters.

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4")

model.profile.max_input_tokens
BeamWeaver.Models.Profile.supports?(model.profile, :tool_calling)
```

Override stale or missing profile data explicitly:

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("openai:future-model",
    profile: %{
      max_input_tokens: 200_000,
      tool_calling: true,
      structured_output: true,
      streaming: true
    }
  )
```

Inspect checked-in profiles:

```bash
mix beam_weaver.models.profiles
mix beam_weaver.models.profiles --provider openai --json
mix beam_weaver.models.profiles --provider xai --json
```

Refresh models.dev-style profile data into a local artifact:

```bash
mix beam_weaver.models.profiles --refresh --provider anthropic --data-dir priv/model_profiles
```

The refresh command is native BeamWeaver tooling; it does not use the Python
`langchain-model-profiles` CLI.

## Multimodal

Messages can carry typed content blocks:

```elixir
alias BeamWeaver.Core.{ContentBlock, Message}

message =
  Message.user([
    ContentBlock.text("Describe this image."),
    ContentBlock.image(%{url: "https://example.com/image.png"})
  ])

BeamWeaver.Core.ChatModel.invoke(model, [message])
```

OpenAI, Anthropic, Google, and xAI translators support the scoped image, audio,
file/document, reasoning, citation, server-tool, and unknown provider blocks
covered by tests.
Video and arbitrary provider-native formats require provider-specific
translation before they should be used in portable BeamWeaver code.

## Reasoning

OpenAI reasoning controls can be passed as request options:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, "Plan the migration.",
  reasoning_effort: :low,
  verbosity: :medium
)
```

Anthropic thinking controls are provider options:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, "Plan the migration.",
  thinking: %{type: :enabled, budget_tokens: 1_024}
)
```

xAI reasoning controls follow OpenAI-compatible request shapes:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, "Plan the migration.",
  reasoning: %{effort: :high}
)
```

Google thinking controls are Gemini generation config options:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, "Plan the migration.",
  thinking_budget: 512,
  include_thoughts: true
)
```

Reasoning output is surfaced as content blocks or stream events when the
underlying provider returns it.

{% hint style="info" %}
**`thinking_level` Is Provider-Specific**

The official Deep Agents models page shows `thinking_level` in a Google GenAI
example. BeamWeaver exposes it only on the Google provider surface. It is not a
portable BeamWeaver option. Use the native control for the provider you are
calling: `:reasoning_effort` or `:reasoning` for OpenAI/xAI, `:thinking` or
`:effort` for Anthropic, and `:thinking_level` or `:thinking_budget` for Google.
{% endhint %}

## Prompt Caching

Prompt caching is provider-specific:

- OpenAI Responses requests support `:prompt_cache_key`.
- Anthropic supports explicit cache blocks through
  `BeamWeaver.Anthropic.Middleware.PromptCaching` and message block metadata.
- Usage metadata preserves cache-read/cache-creation token details when
  providers return them.

{% hint style="info" %}
**Prompt Cache Scope**

Prompt caching is not portable across providers. OpenAI and Anthropic expose
different request fields, cache markers, and usage metadata. BeamWeaver keeps
those controls at the provider boundary instead of inventing a universal cache
wrapper that would hide important provider behavior.
{% endhint %}

## Rate Limiting

Use an explicit limiter and wrapper:

```elixir
{:ok, limiter} =
  BeamWeaver.RateLimiter.TokenBucket.start_link(
    capacity: 10,
    refill_amount: 1,
    refill_interval: 1_000
  )

model =
  BeamWeaver.Models.with_rate_limiter(model,
    limiter: limiter,
    amount: 1,
    timeout: 5_000
  )
```

The limiter controls request count only. It does not estimate request token
weight unless the caller chooses a token-aware policy externally.

## Token Usage And Token Counting

Provider responses store usage on the assistant message:

```elixir
{:ok, message} = BeamWeaver.Core.ChatModel.invoke(model, "Say hello.")
message.usage_metadata
```

Agents aggregate model and tool usage into agent state. Standalone applications
can aggregate `message.usage_metadata` directly or consume telemetry/tracing
events.

Token counting is available when a provider implements it or when a tokenizer is
configured:

```elixir
BeamWeaver.OpenAI.ChatModel.count_tokens(model, [
  BeamWeaver.Core.Message.user("Count this.")
])
```

Anthropic and Google use provider count-token endpoints. OpenAI and xAI can use
tokenizer adapters from profile data or explicit tokenizers. Approximate
counting remains available for fallback behavior.

## Invocation Context

BeamWeaver uses keyword options on model calls:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, "Generate a concise answer.",
  run_id: "run-123",
  metadata: %{user_id: "user-123"},
  tools: [],
  stream_options: %{include_usage: true}
)
```

{% hint style="info" %}
**Invocation Context**

LangChain uses `RunnableConfig` dictionaries for tags, metadata, callbacks,
concurrency limits, and configurable fields. BeamWeaver separates those
concerns: call-specific data is keyword options, monitoring is telemetry and
`BeamWeaver.Tracing`, concurrency is Task/process supervision, and dynamic
model behavior belongs in agent middleware.
{% endhint %}

## Configurable Models

LangChain's `configurable_fields` and `config_prefix` runtime model wrappers map
to explicit Elixir values and middleware:

- build the model you want with `BeamWeaver.Models.init_chat_model/2`
- select dynamic models with agent `wrap_model_call` middleware
- pass provider options as keyword arguments at the call boundary
- use structs when a model configuration should be shared

## Related Guides

- [Partner Matrix](partners.md)
- [OpenAI](partners/openai.md)
- [Anthropic](partners/anthropic.md)
- [Google](partners/google.md)
- [Moonshot/Kimi](partners/moonshot.md)
- [xAI](partners/xai.md)
- [Messages](messages.md)
- [Tools](tools.md)
- [Structured Output](structured_output.md)
- [Rate Limiting](rate_limiting.md)
