# Google Gemini

BeamWeaver calls Gemini models through the Gemini Developer API with
`BeamWeaver.Google.ChatModel`. It supports thinking, Google's built-in tools
such as Google Search and code execution (`BeamWeaver.Google.Tools`),
context caching, token counting, and image, PDF, audio and video input.

## Setup

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :google, api_key: System.get_env("GOOGLE_API_KEY")
```

Export `GOOGLE_API_KEY`, a Gemini API key.

## Models

<!-- generated: provider-models google -->
| Model | Kind | Input tokens | Output tokens | Tools | Structured output | Reasoning | Inputs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `google:gemini-3.1-flash-lite` | chat | 1,048,576 | 65,536 | yes | yes | yes | text, image, PDF, audio, video |
| `google:gemini-3.1-pro-preview` | chat | 1,048,576 | 65,536 | yes | yes | yes | text, image, PDF, audio, video |
| `google:gemini-3.5-flash` | chat | 1,048,576 | 65,536 | yes | yes | yes | text, image, PDF, audio, video |
| `google:gemini-3.5-flash-lite` | chat | 1,048,576 | 65,536 | yes | yes | yes | text, image, PDF, audio, video |
| `google:gemini-3.6-flash` | chat | 1,048,576 | 65,536 | yes | yes | yes | text, image, PDF, audio, video |
| `google:gemini-3.7-flash` | chat | 1,048,576 | 65,536 | yes | yes | yes | text, image, PDF, audio, video |
| `google:gemini-3.8-flash` | chat | 1,048,576 | 65,536 | yes | yes | yes | text, image, PDF, audio, video |
<!-- /generated -->

Gemini ids always need the `google:` prefix; a bare `gemini-3.5-flash` is
rejected.

## Usage

Name the model on the agent's `model` line, with any options after it:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "google:gemini-3.5-flash", max_output_tokens: 4_096
  system_prompt "You are Acme's support agent. Answer in two sentences."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
```

Tools, middleware and memory work as in [Agents](../agents.md). To call the
model without an agent, build it with `BeamWeaver.Models.init_chat_model/2`
(see [Models](../models.md)):

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("google:gemini-3.5-flash")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Write a one-line apology for a late order.")
BeamWeaver.Core.Message.text(reply)
```

## Options

| Option | What it does |
| --- | --- |
| `max_output_tokens` | Output cap; `max_tokens` is the same option. |
| `thinking_level` | How much the model thinks: `:low`, `:medium` or `:high`, and `:minimal` on some models. Gemini 3.7 and 3.8 Flash reject `:minimal` before the request. |
| `thinking_budget` | A token budget for thinking, on models that take one. |
| `include_thoughts` | `true` returns a summary of the model's thinking. |
| `cached_content` | The name of a Gemini cached-content resource. See below. |
| `safety_settings` | Safety thresholds, such as `%{"HARM_CATEGORY_DANGEROUS_CONTENT" => "BLOCK_ONLY_HIGH"}`. |
| `stop_sequences` | Strings that end the answer; `stop` is the same option. |
| `base_url` | The API root, for a proxy. Defaults to `https://generativelanguage.googleapis.com/v1beta`. |

The options shared by every provider, such as `timeout`, are on
[Providers](../providers.md#options-for-every-provider).

## Thinking

Gemini models think before they answer. Set how much with `thinking_level`,
and ask for a summary with `include_thoughts`:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "google:gemini-3.8-flash", thinking_level: :high, include_thoughts: true
  system_prompt "You are Acme's support agent."
end
```

The summary arrives as a `%{type: :reasoning}` block in the reply's
`content`, which `BeamWeaver.Core.Message.text/1` skips. Thinking tokens are
counted in `usage_metadata.output_token_details.reasoning`.

Gemini 3.6, 3.7 and 3.8 Flash and Gemini 3.5 Flash-Lite accept only
`thinking_level`: BeamWeaver rejects `thinking_budget` and the sampling options
`temperature`, `top_p` and `top_k` for them before the request is sent. Gemini
3.5 Flash, 3.1 Flash-Lite and 3.1 Pro Preview also take `thinking_budget` and
sampling options.

## Built-in tools

Google runs these tools on its side. Each helper in `BeamWeaver.Google.Tools`
returns a plain declaration:

```elixir
BeamWeaver.Google.Tools.google_search()
#=> %{"googleSearch" => %{}}
```

Pass declarations with `tools:` on a direct model call, mixed with your own
tools if you like:

```elixir
alias BeamWeaver.Google.Tools

{:ok, model} = BeamWeaver.Models.init_chat_model("google:gemini-3.5-flash")

{:ok, reply} =
  BeamWeaver.Core.ChatModel.invoke(model, "Which carriers deliver to Iceland?",
    tools: [Tools.google_search(), Tools.url_context()]
  )
```

The other helpers are `google_maps/1`, `code_execution/1`, `file_search/2`
(with File Search store names), `computer_use/1` and `mcp_servers/1`.
Computer use is not available on Gemini 3.1 Flash-Lite and 3.1 Pro Preview,
which reject it before the request.

An agent offers built-in tools next to its own when they are in its model
options:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "google:gemini-3.5-flash", tools: [BeamWeaver.Google.Tools.google_search()]
  system_prompt "You are Acme's support agent. Search the web for carrier outages."
end
```

## Context caching

Gemini caches repeated prompt prefixes on its own, and reports the cached
tokens in `usage_metadata.input_token_details.cache_read`. For a large,
stable context, such as a policy manual, create a cached-content resource with
Google's API and pass its name; BeamWeaver doesn't create or expire these
resources:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "google:gemini-3.5-flash", cached_content: "cachedContents/refund-policy-v1"
  system_prompt "You are Acme's support agent."
end
```

`prompt_caching true` has no effect on Gemini. See [Caching](../caching.md).

## Token counting

`BeamWeaver.Google.ChatModel.count_tokens/3` asks Gemini how many input tokens
a request uses:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("google:gemini-3.5-flash")
{:ok, tokens} = BeamWeaver.Google.ChatModel.count_tokens(model, "Where is my order A-1001?")
```

## Limitations

- Only the Gemini Developer API: Vertex AI is not supported.
- BeamWeaver doesn't create, list or delete cached-content resources.
- Image, audio and video generation models have no BeamWeaver wrapper.

## Testing

In tests, use `"fake:chat"` instead of a Gemini model; it needs no key (see
[Testing](../testing.md)). To check the exact requests your code sends,
answer them from a cassette with `transport: BeamWeaver.Transport.Replay`
and `transport_opts: [cassette_path: "test/cassettes/google.yml"]`;
[Replay provider responses](../testing.md#replay-provider-responses) shows
how to write one.

## Reference

- [`BeamWeaver.Google`](https://hexdocs.pm/beam_weaver/BeamWeaver.Google.html): constructors
- [`BeamWeaver.Google.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Google.ChatModel.html): the Gemini model and token counting
- [`BeamWeaver.Google.Tools`](https://hexdocs.pm/beam_weaver/BeamWeaver.Google.Tools.html): built-in tool declarations
