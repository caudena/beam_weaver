# xAI

BeamWeaver calls xAI's Grok models through the Responses API
(`BeamWeaver.XAI.ChatModel`, the default) or Chat Completions
(`BeamWeaver.XAI.ChatCompletionsModel`), and xAI embeddings through
`BeamWeaver.XAI.EmbeddingModel`. It supports reasoning effort, xAI's server
tools such as web search and X search (`BeamWeaver.XAI.Tools`), prompt caching,
stored conversations and the priority tier.

## Setup

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :xai, api_key: System.get_env("XAI_API_KEY")
```

Export `XAI_API_KEY`.

## Models

<!-- generated: provider-models xai -->
| Model | Kind | Input tokens | Output tokens | Tools | Structured output | Reasoning | Inputs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `xai:grok-4.20-0309-non-reasoning` | chat | 1,000,000 | 30,000 | yes | yes | — | text, image |
| `xai:grok-4.20-0309-reasoning` | chat | 1,000,000 | 30,000 | yes | yes | yes | text, image |
| `xai:grok-4.20-multi-agent-0309` | chat | 1,000,000 | 30,000 | yes | yes | yes | text, image |
| `xai:grok-4.3` | chat | 1,000,000 | 30,000 | yes | yes | yes | text, image |
| `xai:grok-4.5` | chat | 500,000 | 30,000 | yes | yes | yes | text, image |
| `xai:grok-4.6` | chat | 500,000 | — | yes | yes | yes | text, image |
| `xai:grok-build-0.1` | chat | 256,000 | 30,000 | yes | yes | yes | text, image |
| `xai:v1` | embedding | — | — | — | — | — | text |
<!-- /generated -->

`grok-4.6` is xAI's general-purpose model and BeamWeaver's default for the
provider. Retired Grok ids are rejected with an error that names the
replacement.

## Usage

Name the model on the agent's `model` line, with any options after it:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "xai:grok-4.6", timeout: 120_000
  system_prompt "You are Acme's support agent. Answer in two sentences."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
```

Tools, middleware and memory work as in [Agents](../agents.md). To call the
model without an agent, build it with `BeamWeaver.Models.init_chat_model/2`
(see [Models](../models.md)):

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("xai:grok-4.6")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Write a one-line apology for a late order.")
BeamWeaver.Core.Message.text(reply)
```

## Options

| Option | What it does |
| --- | --- |
| `api` | `:responses` (default) or `:chat_completions`. |
| `reasoning_effort` | How hard Grok thinks, from `:low` to `:high` (`:xhigh` on Grok 4.6). An effort the model doesn't list is rejected before the request. |
| `max_tokens` | Output cap. |
| `prompt_cache_key` | Routes requests with the same prefix to the same cache, on Responses. |
| `x_grok_conv_id` | The same for Chat Completions, sent as the `x-grok-conv-id` header. |
| `use_previous_response_id` | `true` sends only the messages after xAI's last stored reply, on Responses (see [Stored conversations](#stored-conversations)). |
| `service_tier` | `:priority` for faster processing. |
| `base_url` | The API root, for a proxy. Defaults to `https://api.x.ai/v1`. |

The options shared by every provider, such as `timeout`, are on
[Providers](../providers.md#options-for-every-provider). A `stop:` option
works only on Chat Completions with a non-reasoning model; anywhere else it
returns an `:unsupported_model_param` error before the request. xAI takes no
request metadata, so `metadata:` returns that error too: from
`init_chat_model/2` for a model created with it, and from a call that sends
it. Trace data goes in `trace_metadata:` (see
[Tracing](../tracing.md#name-and-tag-a-run)).

## Reasoning

Grok 4.6 reasons at `:high` effort unless you choose another level:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "xai:grok-4.6", reasoning_effort: :low
  system_prompt "You are Acme's support agent."
end
```

The reasoning text, when xAI returns it, arrives as `%{type: :reasoning}`
blocks in the reply's `content`, which `BeamWeaver.Core.Message.text/1` skips.

A reasoning model sees its earlier thinking only when the next request sends
it back, and xAI returns that thinking, encrypted, only when asked. So on the
Responses API BeamWeaver asks for it on every call to a reasoning model
(`include: ["reasoning.encrypted_content"]`), keeps it in the reply's
reasoning blocks, and sends it back unchanged with the conversation; this
works with `store: false` too. An `include:` list you pass keeps its entries;
`extra_body: %{include: [...]}` replaces the list. Chat Completions has no
field for the encrypted thinking, so there a reasoning model starts each turn
without its earlier thinking; prefer the Responses API for multi-step agents.

## Stored conversations

xAI stores each Responses reply for 30 days unless the request has
`store: false`. With `use_previous_response_id: true`, a call sends only the
messages after the last reply xAI stored, with that reply's id as
`previous_response_id`, and xAI adds the earlier turns itself:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

{:ok, model} = BeamWeaver.Models.init_chat_model("xai:grok-4.6")
history = [Message.user("My order number is A-1001.")]
{:ok, reply} = ChatModel.invoke(model, history, use_previous_response_id: true)

# Sends only the new question, with the id of `reply`.
{:ok, answer} =
  ChatModel.invoke(model, history ++ [reply, Message.user("Which order did I mention?")],
    use_previous_response_id: true
  )
```

In an agent, add it to the model options
(`model "xai:grok-4.6", use_previous_response_id: true`), and each tool round
sends only the tool results. A reply from another provider (after a fallback,
say), from Chat Completions, or made with `store: false` is never continued:
it is sent with the rest of the history. To continue from an id you kept
yourself, pass `previous_response_id:` instead.

## Server tools

xAI runs these tools on its side. Each helper in `BeamWeaver.XAI.Tools`
returns a plain declaration:

```elixir
BeamWeaver.XAI.Tools.web_search(search_depth: :deep)
#=> %{"type" => "web_search", "search_depth" => "deep"}
```

Pass declarations with `tools:` on a direct model call to the Responses API:

```elixir
alias BeamWeaver.XAI.Tools

{:ok, model} = BeamWeaver.Models.init_chat_model("xai:grok-4.6")

{:ok, reply} =
  BeamWeaver.Core.ChatModel.invoke(model, "What are customers saying about Acme's delivery times?",
    tools: [Tools.web_search(), Tools.x_search()]
  )
```

The other helpers are `code_execution/1`, `code_interpreter/1`,
`collections_search/1`, `file_search/1`, `attachment_search/1`, `shell/1`,
`view_image/1`, `view_x_video/1` and `mcp/3`. Chat Completions takes only
`live_search/1` and function tools; BeamWeaver rejects the others there.

An agent offers server tools next to its own when they are in its model
options:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "xai:grok-4.6", tools: [BeamWeaver.XAI.Tools.web_search()]
  system_prompt "You are Acme's support agent. Search the web for carrier outages."
end
```

## Prompt caching

In an agent, `prompt_caching true` derives a cache key from the agent's name,
the model and the system prompt. On Responses it sends the key both as
`prompt_cache_key` and as the `x-grok-conv-id` header; on Chat Completions
only as the header:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "xai:grok-4.6", api: :chat_completions
  system_prompt "You are Acme's support agent. Follow the refund policy below. ..."
  prompt_caching true
end
```

On a direct call, build the key with `BeamWeaver.PromptCache.key/4` and pass it
as `prompt_cache_key:` (Responses) or `x_grok_conv_id:` (Chat Completions).
Cached tokens are reported in `usage_metadata.input_token_details.cache_read`.
See [Caching](../caching.md).

## Embeddings

```elixir
{:ok, embeddings} = BeamWeaver.Models.init_embeddings("xai:v1")
{:ok, vector} = BeamWeaver.Core.EmbeddingModel.embed_query(embeddings, "Where is my order?")
```

## Limitations

- xAI's image, video and voice APIs have no BeamWeaver wrapper.
- `stop` sequences work only on Chat Completions with a non-reasoning model.

## Testing

In tests, use `"fake:chat"` instead of a Grok model; it needs no key (see
[Testing](../testing.md)). To check the exact requests your code sends,
answer them from a cassette with `transport: BeamWeaver.Transport.Replay`
and `transport_opts: [cassette_path: "test/cassettes/xai.yml"]`;
[Replay provider responses](../testing.md#replay-provider-responses) shows
how to write one.

## Reference

- [`BeamWeaver.XAI`](https://hexdocs.pm/beam_weaver/BeamWeaver.XAI.html): constructors
- [`BeamWeaver.XAI.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.XAI.ChatModel.html): the Responses API model
- [`BeamWeaver.XAI.ChatCompletionsModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.XAI.ChatCompletionsModel.html): the Chat Completions model
- [`BeamWeaver.XAI.EmbeddingModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.XAI.EmbeddingModel.html): embeddings
- [`BeamWeaver.XAI.Tools`](https://hexdocs.pm/beam_weaver/BeamWeaver.XAI.Tools.html): server tool declarations
- [`BeamWeaver.XAI.Client`](https://hexdocs.pm/beam_weaver/BeamWeaver.XAI.Client.html): raw client, including deferred completions
