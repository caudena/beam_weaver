# OpenAI

BeamWeaver calls OpenAI's Responses API by default
(`BeamWeaver.OpenAI.ChatModel`) and its Chat Completions API when you ask for
it (`BeamWeaver.OpenAI.ChatCompletionsModel`). The same provider gives you
embeddings (`BeamWeaver.OpenAI.EmbeddingModel`), typed decisions
(`BeamWeaver.OpenAI.DecisionModel`), OpenAI's built-in tools such as web
search (`BeamWeaver.OpenAI.ToolCalling`), image generation and a moderation
middleware.

## Setup

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :openai, api_key: System.get_env("OPENAI_API_KEY")
```

Export `OPENAI_API_KEY`. The same group takes `organization:` and `project:`
to bill requests to an OpenAI organization or project, and `base_url:` to send
every request through a proxy or gateway.

## Models

<!-- generated: provider-models openai -->
| Model | Kind | Input tokens | Output tokens | Tools | Structured output | Reasoning | Inputs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `openai:gpt-4.1` | chat | 1,047,576 | 32,768 | yes | yes | — | text, image, PDF |
| `openai:gpt-5` | chat | 400,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5-mini` | chat | 400,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5-nano` | chat | 400,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5.4` | chat | 1,050,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5.4-mini` | chat | 400,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5.4-nano` | chat | 400,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5.4-pro` | chat | 1,050,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5.5` | chat | 1,050,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5.5-pro` | chat | 1,050,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5.6-luna` | chat | 1,050,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5.6-sol` | chat | 1,050,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-5.6-terra` | chat | 1,050,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-6-astra` | chat | 1,050,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-6-luna` | chat, decision | 1,050,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-6-sol` | chat | 1,050,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:gpt-6.1-sol` | chat | 922,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `openai:text-embedding-3-large` | embedding | 8,191 | — | — | — | — | text |
| `openai:text-embedding-3-small` | embedding | 8,191 | — | — | — | — | text |
<!-- /generated -->

Older ids, such as `gpt-4o` or `o3`, are rejected with an error that names
the replacement.

## Usage

Name the model on the agent's `model` line, with any options after it:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", reasoning_effort: :low
  system_prompt "You are Acme's support agent. Answer in two sentences."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
```

Tools, middleware and memory work as in [Agents](../agents.md). To call the
model without an agent, build it with `BeamWeaver.Models.init_chat_model/2`
(see [Models](../models.md)):

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Write a one-line apology for a late order.")
BeamWeaver.Core.Message.text(reply)
```

## Options

| Option | What it does |
| --- | --- |
| `api` | `:responses` (default) or `:chat_completions`. |
| `reasoning_effort` | How hard a reasoning model thinks: `:none`, `:minimal`, `:low`, `:medium`, `:high`, `:xhigh` or `:max`. Each model accepts a subset, and BeamWeaver rejects the others before the request. |
| `reasoning` | The full reasoning setting, such as `%{effort: :high, summary: :auto}`. |
| `verbosity` | Answer length: `:low`, `:medium` or `:high`. |
| `max_tokens` | Output cap, sent in the field each API and model expects. |
| `service_tier` | Processing tier, such as `:flex` or `:priority`. |
| `prompt_cache_key`, `prompt_cache_options` | Prompt caching; see below. |
| `store` | Whether OpenAI keeps the response on its side. |
| `metadata` | Up to 16 key-value pairs that OpenAI keeps with a stored response (see `store`), to find it later through its API or dashboard: keys of at most 64 characters, and string values of at most 512. Anything else returns an `:unsupported_model_param` error before the request. It is OpenAI's request field; trace data goes in `trace_metadata:` (see [Tracing](../tracing.md#name-and-tag-a-run)). |
| `use_previous_response_id` | `true` sends only the messages after the last reply OpenAI stored, with its id as `previous_response_id`, on Responses. A reply from another provider (after a fallback, say) or made with `store: false` is never continued: it is sent with the rest of the history. |
| `base_url` | The API root, for a proxy. Defaults to `https://api.openai.com/v1`. |
| `endpoint` | The full URL to call, for a proxy or an [OpenAI-compatible server](../providers.md#openai-compatible-servers). |

The options shared by every provider, such as `timeout`, are on
[Providers](../providers.md#options-for-every-provider).

## Responses or Chat Completions

The Responses API is the default, and OpenAI's newer features need it. Ask for
Chat Completions with `api: :chat_completions`, for example to match a service
that speaks only that API:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", api: :chat_completions
  system_prompt "You are Acme's support agent."
end
```

Some newer models restrict tools on Chat Completions, and BeamWeaver rejects
the request before sending it: GPT-6 Astra and GPT-6.1 Sol take tools only on
Responses, and GPT-5.6, GPT-6 Sol and GPT-6 Luna take them on Chat Completions
only with `reasoning_effort: :none`. Reasoning summaries and built-in tools
are rejected on Chat Completions too.

A Chat Completions tool message takes only text, so an image or PDF a tool
returns, such as one from `read_file`, goes in a user message right after the
tool results, under a line naming its call. On Responses it stays in the tool
result.

## Reasoning

Reasoning models think before they answer. `reasoning_effort` trades speed and
cost for depth; `reasoning` also asks for a summary of the model's thinking:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4", reasoning: %{effort: :high, summary: :auto}, timeout: 120_000
  system_prompt "You are Acme's support agent."
end
```

The summary arrives as a `%{type: :reasoning}` block in the reply's `content`,
which `BeamWeaver.Core.Message.text/1` skips. Reasoning tokens are counted in
`usage_metadata.output_token_details.reasoning`. Raise `timeout` for high
effort: the default of 15 seconds is often too short.

Changing `reasoning_effort` partway through a conversation starts the prompt
cache over. GPT-6 models can take the new effort in a `configuration_update`
block instead, which applies from its message on and keeps the cached prefix:

```elixir
BeamWeaver.Core.Message.user([
  %{type: :configuration_update, reasoning: %{effort: :high}},
  "Now analyze the failure modes."
])
```

The Responses API also takes tools added partway through, in an
`additional_tools` block on a system message, such as
`Message.system([%{type: :additional_tools, role: "developer", tools: [...]}])`.
Both blocks go as input items of their own, just before the rest of their
message. Chat Completions has neither: an `additional_tools` block there
returns an `:unsupported_feature` error.

## Built-in tools

OpenAI runs these tools itself, so there is nothing to implement. Each helper
in `BeamWeaver.OpenAI.ToolCalling` returns a plain declaration:

```elixir
BeamWeaver.OpenAI.ToolCalling.web_search()
#=> %{"type" => "web_search_preview"}
```

Pass declarations with `tools:` on a direct model call:

```elixir
alias BeamWeaver.OpenAI.ToolCalling

{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini")

{:ok, reply} =
  BeamWeaver.Core.ChatModel.invoke(model, "What changed in the latest Elixir release?",
    tools: [ToolCalling.web_search(), ToolCalling.code_interpreter()]
  )
```

The search shows up as a `:web_search_call` block in `reply.content`, and its
sources as `annotations` on the text block. The other helpers are
`file_search/2` (with vector store ids), `image_generation/1`, `mcp/3` (a
remote MCP server), `tool_search/1`, `apply_patch/1` and `custom/2`.

An agent offers built-in tools next to its own when they are in its model
options; OpenAI runs them, and the agent runs its `tools`:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", tools: [BeamWeaver.OpenAI.ToolCalling.web_search()]
  system_prompt "You are Acme's support agent. Search the web for carrier outages."
  tools [MyApp.Tools.LookupOrder]
end
```

## Prompt caching

OpenAI caches long prompt prefixes on its own; a `prompt_cache_key` sends
requests with the same prefix to the same cache. In an agent,
`prompt_caching true` derives the key from the agent's name, the model and the
system prompt:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini"
  system_prompt "You are Acme's support agent. Follow the refund policy below. ..."
  prompt_caching true
end
```

On a direct call, build a key with `BeamWeaver.PromptCache.key/4` and pass it
as `prompt_cache_key:`. `prompt_cache_options:`, such as
`%{mode: :explicit, ttl: "30m"}`, turns on explicit caching on models that
offer it. Cached input tokens are reported in
`reply.usage_metadata.input_token_details.cache_read`. See
[Caching](../caching.md).

## Embeddings

```elixir
{:ok, embeddings} = BeamWeaver.Models.init_embeddings("openai:text-embedding-3-small", dimensions: 512)
{:ok, vector} = BeamWeaver.Core.EmbeddingModel.embed_query(embeddings, "Where is my order?")
```

[Retrieval](../retrieval.md) shows embeddings in a vector store.

## Decisions

GPT-6 Luna also answers OpenAI's Decisions API, in public beta: typed
questions about some state, answered with probabilities instead of text.
`init_decision_model/2` creates the decision model, and
`BeamWeaver.Core.DecisionModel.invoke/3` asks it the questions:

```elixir
alias BeamWeaver.OpenAI.Decisions.Question

{:ok, luna} = BeamWeaver.Models.init_decision_model("openai:gpt-6-luna")

{:ok, response} =
  BeamWeaver.Core.DecisionModel.invoke(luna, %{
    state: "Stripe has failed to connect for three days. Help ASAP.",
    questions: %{
      urgent: Question.predicate(instructions: "Is this request urgent?"),
      team:
        Question.choice(
          instructions: "Which team should handle this request?",
          choices: %{"billing" => "Payments and subscriptions.", "technical" => "Bugs and integrations."}
        ),
      mood: Question.score(instructions: "How frustrated is the customer?", levels: ["Calm", "Concerned", "Angry"])
    }
  })

response.answers["team"].choice
```

A predicate is answered with a `probability`, a choice with the chosen value,
the probability of each value and a `confidence`, and a score with the
expected level counted from 0, which may fall between two levels. A choice
takes 2 to 255 values, strings or booleans. A question the model declines
gets a `BeamWeaver.OpenAI.Decisions.RefusalAnswer`.

`state` is a string, user messages with text and images, or other data such
as a conversation or a map, which goes as JSON text with the images of its
messages in place. Images are data URLs or HTTP(S) URLs, at most 128 a
request; turn files, audio and other content into text first. The API doesn't
bill output tokens, so `response.metadata.cost` counts input only.
[`TypeSafeModelRouter`](typesafe.md#route-an-agent) and
[`AutoMode`](../guardrails.md#block-risky-tool-calls) take Luna as their
`classifier:`.

## Images and moderation

`BeamWeaver.OpenAI.generate_image/2` calls the Images API and returns OpenAI's
response, with each image base64-encoded:

<!-- snippet: compile -->
```elixir
{:ok, response} = BeamWeaver.OpenAI.generate_image("A cardboard box with a smile", size: "1024x1024")
[%{"b64_json" => png} | _] = response["data"]
```

`BeamWeaver.Agent.Middleware.OpenAIModeration` checks each user message
before the model sees it, and each answer after, with OpenAI's moderation
endpoint. When something is flagged, the run ends with a refusal:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini"
  system_prompt "You are Acme's support agent."
  middleware [BeamWeaver.Agent.Middleware.OpenAIModeration]
end
```

## Limitations

- Azure OpenAI is not supported.
- GPT-5 models ignore `temperature` unless `reasoning_effort` is `:none`, and
  BeamWeaver drops it without an error. GPT-6 models return an error instead:
  GPT-6 Sol and Luna take it only with `reasoning_effort: :none`, and GPT-6
  Astra and GPT-6.1 Sol not at all.
- OpenAI's hosted multi-agent and programmatic tool calling have no
  BeamWeaver wrapper.

## Testing

In tests, use `"fake:chat"` instead of an OpenAI model; it needs no key (see
[Testing](../testing.md)). To check the exact requests your code sends,
answer them from a cassette with `transport: BeamWeaver.Transport.Replay`
and `transport_opts: [cassette_path: "test/cassettes/openai.yml"]`;
[Replay provider responses](../testing.md#replay-provider-responses) shows
how to write one. To test code that asks GPT-6 Luna for decisions, build it
with `BeamWeaver.OpenAI.decision_model/1` and a `transport:` that returns a
fixed answer, as [TypeSafe's testing section](typesafe.md#testing) shows.

## Reference

- [`BeamWeaver.OpenAI`](https://hexdocs.pm/beam_weaver/BeamWeaver.OpenAI.html): constructors, images and moderation
- [`BeamWeaver.OpenAI.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.OpenAI.ChatModel.html): the Responses API model
- [`BeamWeaver.OpenAI.ChatCompletionsModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.OpenAI.ChatCompletionsModel.html): the Chat Completions model
- [`BeamWeaver.OpenAI.EmbeddingModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.OpenAI.EmbeddingModel.html): embeddings
- [`BeamWeaver.OpenAI.DecisionModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.OpenAI.DecisionModel.html): the Decisions API model
- [`BeamWeaver.OpenAI.Decisions.Question`](https://hexdocs.pm/beam_weaver/BeamWeaver.OpenAI.Decisions.Question.html): predicate, choice and score questions
- [`BeamWeaver.OpenAI.ToolCalling`](https://hexdocs.pm/beam_weaver/BeamWeaver.OpenAI.ToolCalling.html): built-in tool declarations
- [`BeamWeaver.Agent.Middleware.OpenAIModeration`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.OpenAIModeration.html): moderation for agents
- [`BeamWeaver.PromptCache`](https://hexdocs.pm/beam_weaver/BeamWeaver.PromptCache.html): prompt-cache keys
