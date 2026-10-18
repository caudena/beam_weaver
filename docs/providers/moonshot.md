# Moonshot (Kimi)

BeamWeaver calls Moonshot's Kimi models through their OpenAI-compatible Chat
Completions API with `BeamWeaver.Moonshot.ChatModel`. It supports reasoning,
function tools (including Kimi K3's forced and dynamically loaded tools),
structured output, prompt cache keys, token estimates, and image and video
input; `BeamWeaver.Moonshot.Tools` builds Kimi-specific tool declarations.

## Setup

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :moonshot, api_key: System.get_env("MOONSHOT_API_KEY")
```

Export `MOONSHOT_API_KEY`. To use another Moonshot host, set `base_url:` in
the same group.

## Models

<!-- generated: provider-models moonshot -->
| Model | Kind | Input tokens | Output tokens | Tools | Structured output | Reasoning | Inputs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `moonshot:kimi-k2.5` | chat | 262,144 | — | yes | yes | yes | text, image, video |
| `moonshot:kimi-k2.6` | chat | 262,144 | — | yes | yes | yes | text, image, video |
| `moonshot:kimi-k2.7-code` | chat | 262,144 | — | yes | yes | yes | text, image, video |
| `moonshot:kimi-k2.7-code-highspeed` | chat | 262,144 | — | yes | yes | yes | text, image, video |
| `moonshot:kimi-k3` | chat | 1,048,576 | 1,048,576 | yes | yes | yes | text, image, video |
<!-- /generated -->

Kimi ids always need the `moonshot:` prefix. Discontinued Kimi ids are
rejected with an error that names `kimi-k3` as the replacement.

## Usage

Name the model on the agent's `model` line, with any options after it:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "moonshot:kimi-k3", timeout: 120_000
  system_prompt "You are Acme's support agent. Answer in two sentences."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
```

Tools, middleware and memory work as in [Agents](../agents.md). To call the
model without an agent, build it with `BeamWeaver.Models.init_chat_model/2`
(see [Models](../models.md)):

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("moonshot:kimi-k3")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Write a one-line apology for a late order.")
BeamWeaver.Core.Message.text(reply)
```

## Options

| Option | What it does |
| --- | --- |
| `reasoning_effort` | Kimi K3 always reasons and accepts only `:max`. |
| `thinking` | `%{type: :enabled}` or `%{type: :disabled}` on K2.6 and K2.5. K2.7 Code models always think; K3 rejects the option. |
| `max_tokens` | Output cap, sent as `max_completion_tokens`. |
| `prompt_cache_key` | A key that routes requests with the same prefix to the same cache. |
| `base_url` | The API root, for a proxy or another host. Defaults to `https://api.moonshot.ai/v1`. |

The options shared by every provider, such as `timeout`, are on
[Providers](../providers.md#options-for-every-provider), except sampling:
Kimi models use fixed sampling values, and BeamWeaver rejects any other
`temperature` or `top_p` before the request.

Moonshot takes no request metadata, so `metadata:` returns an
`:unsupported_model_param` error before the request; trace data goes in
`trace_metadata:` (see [Tracing](../tracing.md#name-and-tag-a-run)).

## Reasoning

Kimi K3 always reasons at full effort. On K2.6 and K2.5 you choose:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "moonshot:kimi-k2.6", thinking: %{type: :disabled}
  system_prompt "You are Acme's support agent."
end
```

The reasoning text arrives as `%{type: :reasoning}` blocks in the reply's
`content`, which `BeamWeaver.Core.Message.text/1` skips. Agents send it back
with tool results unchanged, as Kimi requires.

## Tools on K3

Kimi K3 accepts `tool_choice: :required`, to force a tool call. K2.6 and K2.5
take `:required` or a named tool only with thinking disabled, and the K2.7
Code models take neither. K3 can also load tools partway through a
conversation:
`BeamWeaver.Moonshot.Tools.dynamic_message/1` returns a system message that
adds them at that point. Here it adds the `lookup_order` tool from the
[Quickstart](../quickstart.md):

```elixir
alias BeamWeaver.Core.Message

messages = [
  Message.user("Where is my order A-1001?"),
  BeamWeaver.Moonshot.Tools.dynamic_message([MyApp.Tools.LookupOrder])
]

{:ok, model} = BeamWeaver.Models.init_chat_model("moonshot:kimi-k3")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, messages)
reply.tool_calls
```

Other Kimi models reject dynamic tool messages before the request.

## Structured output and caching

An agent's `response_schema` works on every Kimi model (see
[Structured Output](../structured_output.md)). K3 and the K2.7 Code models get
the schema as a JSON Schema response format. K2.6 and K2.5 ignore that format,
so BeamWeaver sends them JSON mode with the schema in a system message, and
checks the reply against the schema. With the tool strategy, BeamWeaver forces
the schema tool only where Kimi allows a forced tool choice; elsewhere the
request offers just that tool.

Kimi caches repeated prompt prefixes. In an agent, `prompt_caching true` sets
a `prompt_cache_key` derived from the agent's name, the model and the system
prompt; on a direct call, pass `prompt_cache_key:` yourself. Cached tokens are
reported in `usage_metadata.input_token_details.cache_read`. See
[Caching](../caching.md).

## Images and video

Kimi models read images and video. Pass a `data:` URL, or an `ms://`
reference to a file uploaded to Moonshot; other URLs are rejected before the
request:

```elixir
alias BeamWeaver.Core.{ContentBlock, Message}

question =
  Message.user([
    ContentBlock.text("What is damaged in this video?"),
    ContentBlock.video(url: "ms://file-returns-a1001")
  ])

{:ok, model} = BeamWeaver.Models.init_chat_model("moonshot:kimi-k3")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, [question])
```

An image a tool returns, such as one from `read_file`, goes in a user
message right after the tool results, with the tool's text left in the tool
message. Kimi takes no files such as PDFs, in a tool result or anywhere else:
they return an `:unsupported_feature` error before the request.

`BeamWeaver.Moonshot.ChatModel.count_tokens/3` estimates a request's input
tokens with Moonshot's estimate endpoint.

## Limitations

- Sampling values are fixed by Kimi and can't be changed.
- Kimi's `$web_search` built-in (`BeamWeaver.Moonshot.Tools.web_search/1`)
  works only on K2.6 and K2.5 with thinking disabled, and agents can't run it.
  Kimi lists it as being updated.
- Moonshot's Files, Batch and Balance APIs have no BeamWeaver wrapper; upload
  files with Moonshot's own API, then refer to them with `ms://` URLs.

## Testing

In tests, use `"fake:chat"` instead of a Kimi model; it needs no key (see
[Testing](../testing.md)). To check the exact requests your code sends,
answer them from a cassette with `transport: BeamWeaver.Transport.Replay`
and `transport_opts: [cassette_path: "test/cassettes/moonshot.yml"]`;
[Replay provider responses](../testing.md#replay-provider-responses) shows
how to write one.

## Reference

- [`BeamWeaver.Moonshot`](https://hexdocs.pm/beam_weaver/BeamWeaver.Moonshot.html): constructors
- [`BeamWeaver.Moonshot.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Moonshot.ChatModel.html): the Kimi chat model and token estimates
- [`BeamWeaver.Moonshot.Tools`](https://hexdocs.pm/beam_weaver/BeamWeaver.Moonshot.Tools.html): web search and dynamic tool declarations
