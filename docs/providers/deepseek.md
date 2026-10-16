# DeepSeek

BeamWeaver calls DeepSeek's V4 models through its Chat Completions API
(`BeamWeaver.DeepSeek.ChatModel`, the default) or its Responses API
(`BeamWeaver.DeepSeek.ResponsesModel`). It supports thinking mode, image input
on Flash, hosted web search on Responses, DeepSeek's beta features, and a raw
client for fill-in-the-middle completion and account calls
(`BeamWeaver.DeepSeek.Client`).

## Setup

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :deepseek, api_key: System.get_env("DEEPSEEK_API_KEY")
```

Export `DEEPSEEK_API_KEY`.

## Models

<!-- generated: provider-models deepseek -->
| Model | Kind | Input tokens | Output tokens | Tools | Structured output | Reasoning | Inputs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `deepseek:deepseek-flash` | chat | 1,048,576 | 393,216 | yes | yes | yes | text, image |
| `deepseek:deepseek-v4-flash` | chat | 1,048,576 | 393,216 | yes | yes | yes | text, image |
| `deepseek:deepseek-v4-flash-vision-exp` | chat | 1,048,576 | 393,216 | yes | yes | yes | text, image |
| `deepseek:deepseek-v4-pro` | chat | 1,048,576 | 393,216 | yes | yes | yes | text |
<!-- /generated -->

`deepseek-flash` is DeepSeek V4.1 Flash; `deepseek-v4-flash` and
`deepseek-v4-flash-vision-exp` are older names for the same model. The retired
`deepseek-chat` and `deepseek-reasoner` ids are rejected rather than mapped
to a different model, and every id needs the `deepseek:` prefix.

## Usage

Name the model on the agent's `model` line, with any options after it:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "deepseek:deepseek-flash", timeout: 120_000
  system_prompt "You are Acme's support agent. Answer in two sentences."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
```

Tools, middleware and memory work as in [Agents](../agents.md). To call the
model without an agent, build it with `BeamWeaver.Models.init_chat_model/2`
(see [Models](../models.md)):

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("deepseek:deepseek-flash")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Write a one-line apology for a late order.")
BeamWeaver.Core.Message.text(reply)
```

## Options

| Option | What it does |
| --- | --- |
| `api` | `:chat_completions` (default) or `:responses`. |
| `thinking` | `%{type: :enabled}` (the default) or `%{type: :disabled}`, on Chat Completions. |
| `reasoning_effort` | `:low`, `:high` or `:max`; `:none` turns thinking off. |
| `reasoning` | The Responses form, such as `%{effort: :high}`. |
| `max_tokens` | Output cap. |
| `base_url` | The API root, for a proxy. Defaults to `https://api.deepseek.com`. |

The options shared by every provider, such as `timeout`, are on
[Providers](../providers.md#options-for-every-provider). DeepSeek models think
by default and can take a while, so raise `timeout` from its 15-second
default.

DeepSeek takes no request metadata, so `metadata:` returns an
`:unsupported_model_param` error before the request; trace data goes in
`trace_metadata:` (see [Tracing](../tracing.md#name-and-tag-a-run)).

## Thinking and tool choice

Thinking is on by default, and its text arrives as `%{type: :reasoning}`
blocks in the reply's `content`. When the model calls a tool, BeamWeaver sends
that reasoning back with the tool result, as DeepSeek requires.

In thinking mode, DeepSeek decides on its own whether to call a tool, so
BeamWeaver rejects a forced `tool_choice` such as `:required` before the
request. To force a tool, turn thinking off for that model:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("deepseek:deepseek-flash", thinking: %{type: :disabled})
```

## Chat Completions or Responses

Chat Completions is the default. `api: :responses` switches to DeepSeek's
Responses API, which adds hosted web search
(`BeamWeaver.DeepSeek.Tools.web_search/1`), the `apply_patch` tool
(`BeamWeaver.DeepSeek.Tools.apply_patch/1`) and native JSON Schema output:

```elixir
alias BeamWeaver.DeepSeek.Tools

{:ok, model} = BeamWeaver.Models.init_chat_model("deepseek:deepseek-flash", api: :responses)

{:ok, reply} =
  BeamWeaver.Core.ChatModel.invoke(model, "Which carriers deliver to Iceland?",
    tools: [Tools.web_search()],
    reasoning: %{effort: :high}
  )
```

DeepSeek stores nothing between Responses calls, so BeamWeaver sends the full
history every turn and rejects stateful options such as
`previous_response_id`. On Chat Completions, DeepSeek has only a JSON object
mode: for structured output, BeamWeaver adds the schema to the prompt and
validates the answer itself (see [Structured Output](../structured_output.md)).

## Images

Flash reads JPEG, PNG, GIF and WebP images in user messages and tool results;
V4 Pro is text only:

```elixir
alias BeamWeaver.Core.{ContentBlock, Message}

question =
  Message.user([
    ContentBlock.text("What is damaged in this photo?"),
    ContentBlock.image(url: "https://example.com/returns/A-1001.jpg")
  ])

{:ok, model} = BeamWeaver.Models.init_chat_model("deepseek:deepseek-flash")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, [question])
```

## Beta features

DeepSeek offers some features on a separate beta endpoint. BeamWeaver sends a
request there automatically when it uses strict function tools or prefix
completion (a final assistant message with `metadata: %{prefix: true}`, which
the model continues), and you can send any call there with `beta: true`:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("deepseek:deepseek-flash")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Summarize ticket 42.", beta: true)
```

## Raw client

`BeamWeaver.DeepSeek.Client` calls DeepSeek's other endpoints with plain maps:
fill-in-the-middle code completion (which runs without thinking), the model
list and the account balance:

<!-- snippet: compile -->
```elixir
client = BeamWeaver.DeepSeek.Client.new()

{:ok, response} =
  BeamWeaver.DeepSeek.Client.completions(client, %{
    "model" => "deepseek-flash",
    "prompt" => "defmodule Orders do\n  def shipped?(order) do\n",
    "suffix" => "  end\nend\n",
    "max_tokens" => 64
  })

{:ok, balance} = BeamWeaver.DeepSeek.Client.balance(client)
```

## Errors

DeepSeek ends a reply it couldn't finish with the finish reason
`insufficient_system_resource` (it ran out of resources) or `aborted` (it
interrupted the reply). The call then fails, with or without streaming, with
a server error that `ModelRetry` retries, instead of returning the cut-off
reply. A reply that its content filter shortened is still a reply, with
`status: "content_filter"`.

## Limitations

- Chat Completions has no native JSON Schema mode; schemas are enforced by
  local validation.
- A forced tool choice needs thinking off.
- DeepSeek caches repeated prompt prefixes on its own and reports them in
  `usage_metadata.input_token_details.cache_read`; there is no cache key to
  set, and `prompt_caching true` has no effect.
- Images are the only media input; audio, video and files are not supported.

## Testing

In tests, use `"fake:chat"` instead of a DeepSeek model; it needs no key (see
[Testing](../testing.md)). To check the exact requests your code sends,
answer them from a cassette with `transport: BeamWeaver.Transport.Replay`
and `transport_opts: [cassette_path: "test/cassettes/deepseek.yml"]`;
[Replay provider responses](../testing.md#replay-provider-responses) shows
how to write one.

## Reference

- [`BeamWeaver.DeepSeek`](https://hexdocs.pm/beam_weaver/BeamWeaver.DeepSeek.html): constructors
- [`BeamWeaver.DeepSeek.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.DeepSeek.ChatModel.html): the Chat Completions model
- [`BeamWeaver.DeepSeek.ResponsesModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.DeepSeek.ResponsesModel.html): the Responses model
- [`BeamWeaver.DeepSeek.Tools`](https://hexdocs.pm/beam_weaver/BeamWeaver.DeepSeek.Tools.html): web search and `apply_patch` declarations
- [`BeamWeaver.DeepSeek.Client`](https://hexdocs.pm/beam_weaver/BeamWeaver.DeepSeek.Client.html): raw client for every DeepSeek endpoint
