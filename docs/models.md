# Models

A chat model takes a conversation and returns the next assistant message.
Agents call their model for you; call a model directly for single tasks such as
summarizing or classifying text.

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

{:ok, model} = BeamWeaver.Models.init_chat_model("fake:chat", responses: ["Your order is on its way."])

{:ok, reply} = ChatModel.invoke(model, "Where is my order A-1001?")
Message.text(reply)
#=> "Your order is on its way."
```

`"fake:chat"` is a scripted model built into BeamWeaver, so the examples on
this page run without an API key. [Fake models](#fake-models) shows how to
script it.

## Name a model

A model is named `"provider:model"`, such as `"anthropic:claude-haiku-4-5"`.
The providers are `openai`, `anthropic`, `google`, `xai`, `deepseek`,
`moonshot` and `zai`, plus `fake` for tests. [Providers](providers.md) lists
the models of each one, and this task prints every model BeamWeaver knows:

```bash
mix beam_weaver.models.profiles
mix beam_weaver.models.profiles --provider anthropic
```

Always write the prefix. A few bare names are recognized (`gpt-*` for OpenAI,
`claude-*` for Anthropic, `grok-*` for xAI), Gemini,
Kimi, GLM and DeepSeek names are rejected without theirs, and any other bare
name is taken as an OpenAI model:

```elixir
BeamWeaver.Models.init_chat_model("gemini-3.5-flash")
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_model}}
```

## Create a model

`BeamWeaver.Models.init_chat_model/2` returns `{:ok, model}` or
`{:error, %BeamWeaver.Core.Error{}}`; `BeamWeaver.Models.init_chat_model!/2`
returns the model or raises. Creating a model doesn't contact the provider.

```elixir
{:ok, haiku} = BeamWeaver.Models.init_chat_model("anthropic:claude-haiku-4-5", temperature: 0.2, max_tokens: 1_024)

mini = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", timeout: 60_000)
```

### Common options

| Option | Meaning |
| --- | --- |
| `api_key:` | Overrides the key from your configuration (see [API keys](#api-keys)). |
| `temperature:` | Sampling temperature, for models that accept it. |
| `max_tokens:`, `max_output_tokens:` | The longest reply; every provider takes both names. |
| `timeout:` | How long to wait for the provider, in milliseconds (15 seconds by default). |
| `top_p:` | Nucleus sampling. |
| `stream:` | `true` makes an agent stream this model's replies. |
| `extra_body:` | Raw request fields for provider features BeamWeaver doesn't model. |
| `profile:` | Replaces the model's profile (see [Model profiles](#model-profiles)). |

Each provider page lists its own options, such as reasoning effort, thinking
and prompt caching. An option the provider doesn't take is an error, so a
misspelled one never goes unnoticed:

```elixir
BeamWeaver.Models.init_chat_model("fake:chat", temprature: 0.2)
#=> {:error, %BeamWeaver.Core.Error{type: :unsupported_model_param, details: %{params: [:temprature]}}}
```

Options that belong to a call, such as `tools:` or `tool_choice:`, go with
each call instead (see [Call a model](#call-a-model)).

## Models in agents

An agent's `model` declaration takes a `"provider:model"` string and options,
or a model you created. BeamWeaver creates the model from the string and also
passes the options on each call:

```elixir
defmodule MyApp.ConfiguredModelAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", temperature: 0.2, timeout: 60_000
end

{:ok, result} = MyApp.ConfiguredModelAgent.invoke(%{messages: ["Reply with the word ready."]})
true = is_binary(result.messages |> List.last() |> BeamWeaver.Core.Message.text())
```

`timeout:` also limits the agent's model step, so raise it for long replies.
Call options can go there too, such as `tools:` with a provider's built-in
tools, which the agent offers next to its own (see the provider pages). To
change options for a single run, pass `model_opts:` to `invoke/2`.

Providers don't retry failed calls on their own. In an agent, the
`ModelRetry` middleware retries temporary errors such as timeouts and rate
limits, and `ModelFallback` tries other models when a call fails. A fallback
is a `"provider:model"` string or, as here, a model value with its own
options:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.ModelFallback

  model "fake:chat", error: BeamWeaver.Core.Error.new(:rate_limit, "Too many requests")

  middleware [
    {ModelFallback, fallbacks: [BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["The backup model answered."])]}
  ]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
result.messages |> List.last() |> Message.text()
#=> "The backup model answered."
```

The first middleware in the list wraps the others. List `ModelFallback`
before `ModelRetry`, and each model gets all its attempts before the next one
takes over:

```elixir
defmodule MyApp.FallbackAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  middleware [
    {BeamWeaver.Agent.Middleware.ModelFallback, fallbacks: ["anthropic:claude-haiku-4-5"]},
    {BeamWeaver.Agent.Middleware.ModelRetry, max_attempts: 3}
  ]
end

{:ok, result} = MyApp.FallbackAgent.invoke(%{messages: ["Reply with the word ready."]})
true = is_binary(result.messages |> List.last() |> BeamWeaver.Core.Message.text())
```

[Built-in Middleware](builtin_middleware.md) lists the retry options.

### Images and PDFs

An agent sends each model only the images and PDFs it can take. When the
thread holds an image, such as one `read_file` returned, and the model's
built-in profile has `image_inputs: false` (DeepSeek V4 Pro, say), the
request carries a short notice in its place:
`[An image was left out: this model doesn't take images.]`. An inline PDF
goes the same way by `pdf_inputs`, with the notice naming the file. Only the
request changes: the thread keeps the media, so a fallback or a later model
that takes it gets it. Subagents do the same, and the check runs after the
agent's own middleware, on the model that `ModelFallback` picked.

A model with a `profile:` you declared yourself, or one BeamWeaver has no
profile for, gets the media as it is. Declaring a profile is also how to send
the media when BeamWeaver's profile is wrong for a model.

### Defaults for agent models

`BeamWeaver.Agent.ProviderProfile` registers default options for every agent
model of a provider, or of one model. Register them once, when your
application starts:

```elixir
alias BeamWeaver.Agent.ProviderProfile

:ok = ProviderProfile.register_provider_profile("anthropic", ProviderProfile.new(init_kwargs: [timeout: 60_000]))
:ok = ProviderProfile.register_provider_profile("anthropic:claude-haiku-4-5", ProviderProfile.new(init_kwargs: [temperature: 0.2]))
```

The defaults apply when an agent's `model` is a `"provider:model"` string. A
model-level entry adds to its provider's entry, and the options in the `model`
declaration win over both. Models you create with `init_chat_model/2` don't
use them.

## Call a model

`BeamWeaver.Core.ChatModel.invoke/3` takes a string, which becomes a user
message, or a list of messages (see [Messages](messages.md)). It returns
`{:ok, reply}` or `{:error, %BeamWeaver.Core.Error{}}`:

```elixir
history = [
  Message.system("You are Acme's support agent. Answer in one sentence."),
  Message.user("Where is my order A-1001?")
]

{:ok, reply} = ChatModel.invoke(model, history)
{reply.role, Message.text(reply)}
#=> {:assistant, "Your order is on its way."}
```

The third argument takes call options, such as `temperature:` for one call or
`tools:` to offer the model tools. A model only asks for tool calls; it doesn't
run them. [Messages](messages.md#tool-calls-and-tool-results) shows the round
trip, and an [agent](agents.md) runs it for you.

`BeamWeaver.Core.ChatModel.batch/3` calls the model once per input, in order,
and returns the results in the same order:

```elixir
ChatModel.batch(model, ["Where is order A-1001?", "Where is order A-1002?"])
#=> [{:ok, %BeamWeaver.Core.Message{role: :assistant}}, {:ok, %BeamWeaver.Core.Message{role: :assistant}}]
```

To call a provider in parallel, use `Task.async_stream/3`:

```elixir
["Where is order A-1001?", "Where is order A-1002?"]
|> Task.async_stream(&ChatModel.invoke(model, &1), timeout: 60_000)
|> Enum.map(fn {:ok, {:ok, reply}} -> Message.text(reply) end)
#=> ["Your order is on its way.", "Your order is on its way."]
```

### Stream a reply

`BeamWeaver.Core.ChatModel.stream_typed_events/3` returns the reply as a
stream of typed events, such as `Token` for text as it arrives, `Message` for
the whole reply, and `Done` at the end. The fake model streams one word at a
time:

```elixir
{:ok, events} = ChatModel.stream_typed_events(model, "Where is my order A-1001?")

for %BeamWeaver.Stream.Envelope{event: %BeamWeaver.Stream.Events.Token{text: text}} <- events, do: text
#=> ["Your ", "order ", "is ", "on ", "its ", "way."]
```

If the provider fails, for example because the model is overloaded, the stream
has an `Error` event instead of `Message` and `Done`, even when the failure
comes partway through the reply. The error is the one the same failure gets
without streaming, with the same type and `details.retryable`. A failure whose
code no provider documents counts as a server error, which `ModelRetry`
retries; the first time a provider sends such a code, BeamWeaver logs a
warning that names the provider and the code, so you can report it. A call
that BeamWeaver rejects before sending it, such as one without an API key,
returns `{:error, error}` instead of a stream.

Z.ai and DeepSeek report some failures with the reply's finish reason instead
of an error: Z.ai's `network_error` (its inference failed) and `sensitive`
(its safety review blocked the reply), and DeepSeek's
`insufficient_system_resource` and `aborted`. Such a call fails too, with or
without streaming: `sensitive` is a `:content_filter` error that isn't retried,
the others are server errors that `ModelRetry` retries. A reply that ends for
any other reason, such as its length limit or OpenAI's content filter, is still
a reply; its `status` says why it ended.

To stream from an agent, add `stream: true` to its model options and call
`stream_events/2` with `live: true`. [Streaming](streaming.md) covers events,
chunks and tool-call deltas.

### Errors

A failed call's `type` says what went wrong, the same for every provider, and
`details.retryable` whether trying again can help. `details.status` and
`details.code` keep the provider's HTTP status and error code:

| Type | When | Retryable |
|---|---|---|
| `:invalid_request` | the provider rejects the request (HTTP 400 or 422) | no |
| `:authentication` | the API key is wrong (401; a 400 from Gemini and xAI) | no |
| `:permission_denied` | the key may not use the model or feature (403) | no |
| `:not_found` | the model doesn't exist (404) | no |
| `:rate_limit` | too many requests (429) | yes |
| `:server_error` | the provider failed or is overloaded (5xx) | yes |
| `:connection` | the request got no response | yes |
| `:timeout` | the request ran past its timeout | yes |
| `:context_overflow` | the prompt doesn't fit the model's context window | no |
| `:billing_exhausted` | credits, a spend limit or a usage limit ran out | no |
| `:content_filter` | Z.ai's or Kimi's content filter blocked the request | no |

Any other HTTP status is an `:http_error`, retryable for 408, 409 and 425. A
request the transport refuses, such as one that matches no cassette in a test,
is a `:transport_error`. `ModelRetry` retries only the retryable errors (see
[Built-in Middleware](builtin_middleware.md#modelretry)).

### Cache and rate-limit a model

`BeamWeaver.Models.cached/3` wraps a model so that repeated requests are
answered from a cache, and `BeamWeaver.Models.with_rate_limiter/2` wraps it so
that calls wait for a rate limiter. You use the wrapped model like any other.
See [Caching](caching.md) and [Rate Limiting](rate_limiting.md).

## Reasoning

Reasoning models work through a problem before they answer. Each provider
names its reasoning controls differently:

| Provider | Options |
| --- | --- |
| OpenAI, xAI | `reasoning_effort:`, or `reasoning:` as a map |
| Anthropic | `reasoning_effort:` (or `effort:`) and `thinking:` |
| Google | `thinking_level:` or `thinking_budget:`, and `include_thoughts:` |
| DeepSeek, Z.ai | `thinking:` and `reasoning_effort:` |
| Moonshot | `thinking:` on Kimi K2 models, `reasoning_effort:` on Kimi K3 |

Set them when you create the model, or per call:

```elixir
{:ok, reasoning_model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", reasoning_effort: :low)
{:ok, reasoning_reply} = BeamWeaver.Core.ChatModel.invoke(reasoning_model, "What is 2 + 2?")
true = byte_size(BeamWeaver.Core.Message.text(reasoning_reply)) > 0
```

A model's profile lists the efforts it takes in `reasoning_effort_levels`, and
the one it uses when you name none in `reasoning_effort_default`; the provider
pages say more. When a provider returns its reasoning, the reply's content
holds `:reasoning` blocks (see [Messages](messages.md)).

## Model profiles

Every known model has a profile: its context window, output limit, and the
features it supports, such as tools, structured output, streaming, reasoning
and image input. `BeamWeaver.Provider.Compatibility.supports?/2` checks a
feature on a model, a profile, or a `{provider, model}` pair:

```elixir
alias BeamWeaver.Provider.Compatibility

[
  Compatibility.supports?({:anthropic, "claude-haiku-4-5"}, :image_input),
  Compatibility.supports?(model, :tool_calling),
  Compatibility.supports?(model, :reasoning)
]
#=> [true, true, false]
```

`BeamWeaver.Provider.Compatibility.features/0` lists the feature names. The
profile itself is `model.profile`, a `BeamWeaver.Models.Profile` struct with
fields such as `max_input_tokens` and `max_output_tokens`.

BeamWeaver checks each call against the profile before it sends anything. A
call that asks for a feature the model lacks fails at once. The fake model has
no reasoning, so it rejects a reasoning effort:

```elixir
ChatModel.invoke(model, "Where is my order A-1001?", reasoning_effort: :high)
#=> {:error, %BeamWeaver.Core.Error{type: :unsupported_feature, details: %{feature: :reasoning}}}
```

Every provider also rejects a call option the profile doesn't list, such as
`top_k:`, with an `:unsupported_model_param` error, and checks values the
profile lists, such as a model's reasoning efforts. An agent sends its model
options on every call, so this applies to them too.

A model name BeamWeaver doesn't know yet gets its family's profile (such as
`claude-*` or `gemini-*`), or else a bare one with tools and structured output
switched off; OpenAI, DeepSeek and Z.ai reject some unknown names. Pass
`profile:` to override a model's limits in your application. Start from its
existing profile so its other capabilities remain accurate:

```elixir
base_model = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")

{:ok, constrained_model} =
  BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini",
    profile: %{base_model.profile | max_input_tokens: 8_000}
  )

8_000 = constrained_model.profile.max_input_tokens
{:ok, reply} = ChatModel.invoke(constrained_model, "Reply with OK.")
true = byte_size(BeamWeaver.Core.Message.text(reply)) > 0
```

## Embeddings

An embedding model turns text into vectors for [retrieval](retrieval.md#embeddings).
`BeamWeaver.Models.init_embeddings/2` creates one, and
`BeamWeaver.Core.EmbeddingModel` embeds documents and queries:

```elixir
alias BeamWeaver.Core.EmbeddingModel

{:ok, embeddings} = BeamWeaver.Models.init_embeddings("fake:embedding")

{:ok, vectors} = EmbeddingModel.embed_documents(embeddings, ["Refunds take 5 days.", "Orders ship in 2 days."])
{:ok, vector} = EmbeddingModel.embed_query(embeddings, "How long do refunds take?")

{length(vectors), length(vector)}
#=> {2, 3}
```

`"fake:embedding"` returns the same 3-number vector for the same text (set
`dimensions:` to change the size). Its vectors carry no meaning, so search
results with it come back in arbitrary order. A real embedding model reads its key from the provider's config group, like a
chat model:

```elixir
{:ok, embeddings} = BeamWeaver.Models.init_embeddings("openai:text-embedding-3-small")
```

## Token usage

Replies carry the token counts the provider reports in `usage_metadata`:
`input_tokens`, `output_tokens` and `total_tokens`, plus provider details
such as `input_token_details` (cache reads) and `output_token_details`
(reasoning tokens) when the provider sends them. The
fake model reports whatever you give it:

```elixir
{:ok, counted} =
  BeamWeaver.Models.init_chat_model("fake:chat",
    responses: ["Your order is on its way."],
    usage_metadata: %{input_tokens: 12, output_tokens: 6, total_tokens: 18}
  )

{:ok, reply} = ChatModel.invoke(counted, "Where is my order A-1001?")
reply.usage_metadata
#=> %{input_tokens: 12, output_tokens: 6, total_tokens: 18}
```

`BeamWeaver.Agent.Usage.from_messages/1` adds up the replies in an agent's
`result.messages`:

```elixir
usage = BeamWeaver.Agent.Usage.from_messages([Message.user("Hi"), reply, reply])
{usage.total_tokens, usage.model_calls}
#=> {36, 2}
```

`BeamWeaver.Models.UsageCost.calculate/3` turns usage into a cost with the
prices in a model's profile. [Tracing](tracing.md) records usage for every
model call.

## Decision models

Decision models answer typed questions about a piece of state instead of
writing text: a choice between options, a score on a scale, or true or false.
`BeamWeaver.Models.init_decision_model/2` creates one, such as TypeSafe's
`"typesafe:jev-1.13.0"` or OpenAI's `"openai:gpt-6-luna"`, and
`BeamWeaver.Core.DecisionModel.invoke/3` asks it the questions. Each provider
has its own questions; see [TypeSafe](providers/typesafe.md) and
[OpenAI](providers/openai.md#decisions).

Code that works with either provider builds its question with
`DecisionModel.choice_question/3` or `DecisionModel.yes_no_question/2`, then
asks it with `DecisionModel.choose/4` or `DecisionModel.probability/4`:

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

[`TypeSafeModelRouter`](providers/typesafe.md#route-an-agent) and
[`AutoMode`](guardrails.md#block-risky-tool-calls) ask their `classifier:` this
way.

## API keys

Providers read their API key from the application configuration. Load the keys
from the environment in `config/runtime.exs`:

```elixir
import Config

config :beam_weaver, :openai, api_key: System.get_env("OPENAI_API_KEY")
config :beam_weaver, :anthropic, api_key: System.get_env("ANTHROPIC_API_KEY")
config :beam_weaver, :google, api_key: System.get_env("GOOGLE_API_KEY")
```

The other providers use their prefix as the key, such as `:xai`.
[Providers](providers.md) covers the setup and options of each provider.

## Fake models

`"fake:chat"` replies from a script instead of a provider. Each entry of
`responses:` is one reply: the first reply in a conversation is the first
entry, the next reply the second, and the last entry repeats once the script
runs out.

| Entry | The model's reply |
| --- | --- |
| `"Your order is on its way."` | This text. |
| `FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"})` | A call to one tool. |
| `FakeChatModel.tool_calls([{"lookup_order", %{...}}, ...])` | Calls to several tools at once. |
| `FakeChatModel.final(%{"category" => "shipping"})` | A structured answer (see [Structured Output](structured_output.md)). |
| a `%BeamWeaver.Core.Message{}` | This message. |

Other options: `stream: true` makes an agent stream the reply word by word,
`usage_metadata:` adds token counts, `parent:` sends every request to a
process, and `error:` makes every call fail:

```elixir
{:ok, failing} =
  BeamWeaver.Models.init_chat_model("fake:chat", error: BeamWeaver.Core.Error.new(:rate_limit, "Too many requests"))

ChatModel.invoke(failing, "Where is my order A-1001?")
#=> {:error, %BeamWeaver.Core.Error{type: :rate_limit}}
```

[Testing](testing.md) shows how to test agents with fake models.

## Reference

- [`BeamWeaver.Models`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.html): create chat, embedding and decision models
- [`BeamWeaver.Core.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.ChatModel.html): call, batch and stream chat models
- [`BeamWeaver.Core.EmbeddingModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.EmbeddingModel.html): embed documents and queries
- [`BeamWeaver.Provider.Compatibility`](https://hexdocs.pm/beam_weaver/BeamWeaver.Provider.Compatibility.html): check what a model supports
- [`BeamWeaver.Models.Profile`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.Profile.html): model capability data
- [`BeamWeaver.Agent.Usage`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Usage.html): token totals for an agent run
- [`BeamWeaver.Models.FakeChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.FakeChatModel.html): the scripted chat model
- [`BeamWeaver.Models.FakeEmbeddingModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.FakeEmbeddingModel.html): the deterministic embedding model
