# Providers

BeamWeaver calls provider APIs directly. Seven integrations generate chat;
TypeSafe supplies typed decisions. OpenAI also supplies decisions and
embeddings. Choose the operation first, then a model that supports the tools,
media and output contract your application needs.

## Start with a real call

The [OpenAI](providers/openai.md) and [Google](providers/google.md) guides
begin with configuration and an executed request. The
[Quickstart](quickstart.md) puts the same model behind an agent module.
Each provider guide separates its implemented endpoints from native services
that require your own executor or resource-management code.

With the OpenAI key configured as in Installation, initialize and invoke a model directly:

```elixir
model = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Explain a tracking number briefly.")
true = byte_size(BeamWeaver.Core.Message.text(reply)) > 0
```

## Supported providers

| Provider | Model IDs | Chat capabilities |
| --- | --- | --- |
| [OpenAI](providers/openai.md) (`openai:`) | 17 chat, 1 decision, 2 embedding | Tools: all; structured output: all; reasoning: 16 of 17; images: all |
| [Anthropic](providers/anthropic.md) (`anthropic:`) | 19 chat | Tools: all; structured output: 16 of 19; reasoning: all; images: all |
| [Google Gemini](providers/google.md) (`google:`) | 7 chat | Tools: all; structured output: all; reasoning: all; images: all |
| [xAI](providers/xai.md) (`xai:`) | 8 chat | Tools: all; structured output: all; reasoning: 7 of 8; images: all |
| [Moonshot (Kimi)](providers/moonshot.md) (`moonshot:`) | 4 chat | Tools: all; structured output: all; reasoning: all; images: all |
| [Z.ai](providers/zai.md) (`zai:`) | 8 chat | Tools: all; structured output: all; reasoning: all; images: 2 of 8 |
| [DeepSeek](providers/deepseek.md) (`deepseek:`) | 4 chat | Tools: all; structured output: all; reasoning: all; images: 3 of 4 |
| [TypeSafe](providers/typesafe.md) (`typesafe:`) | 3 decision | Typed decisions; no chat model |

This table describes checked-in model profiles. Counts include aliases and
snapshots; they are not distinct-model counts or a statement of your account's
access. `mix beam_weaver.models.profiles` prints the local registry. Actual
availability is established by an authenticated call.

## Model strings

Use an explicit `provider:model` identifier. Model initialization resolves
an adapter and validates local options; it does not authenticate or send an
inference request. Some bare names are recognized, but explicit prefixes
avoid ambiguity. Known discontinued IDs fail with replacement guidance rather
than silently changing models.

Model profiles describe API capabilities. Behavioral capability profiles tune
agent prompts/tools. These are different concepts; see [Models](models.md)
and [Capability Profiles](profiles.md).

## Credentials

Configure only the providers your application uses in its own runtime config.
An explicit model key overrides its provider's configured key. Missing keys
fail before HTTP execution. The library does not automatically read a consumer's
`.env`; repository example scripts have their own credential loader.

[Configuration](configuration.md#provider-groups) lists provider groups and
connection fields. Keep credentials out of source, trace fields and sandbox
environments. A custom endpoint must receive credentials intended for that
endpoint, not an accidentally inherited production provider key.

## Options for every provider

| Option | Scope |
| --- | --- |
| `api_key:`, `base_url:` | Credentials and connection defaults |
| `timeout:` | Request milliseconds, default 15,000 |
| `max_tokens:` / `max_output_tokens:` | Output budget |
| `temperature:`, `top_p:` | Only where the selected model accepts them |
| `extra_body:` | Additional native fields, still subject to server validation |
| `transport:`, `transport_opts:` | Explicit HTTP/replay adapter |
| `profile:` | Local compatibility metadata override |

An `endpoint:` usually means a full request URL; Google treats it as an API
root. Reasoning, caching, tool choice and metadata differ by endpoint/model.
Consult the dedicated guide before moving options between providers.

## Switching and fallback

Change the model identifier and review provider-specific options. Native
reasoning blocks are replayed only to compatible provider endpoints; preserving
full message objects lets codecs retain the information they need.

`ModelFallback` changes the model after failure and uses its own credentials.
`ModelRetry` adds bounded retries; providers do not retry independently.
A fallback success does not establish that the primary integration worked.
[Built-in Middleware](builtin_middleware.md) explains ordering and budgets.

Run the same provider-neutral request with two actual integrations. Configure both keys before this block:

```elixir
for spec <- ["openai:gpt-5.4-mini", "google:gemini-3.5-flash"] do
  model = BeamWeaver.Models.init_chat_model!(spec, max_tokens: 256, timeout: 60_000)
  {:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Define parcel tracking in one sentence.")
  true = byte_size(BeamWeaver.Core.Message.text(reply)) > 0
  IO.puts("#{spec}: #{BeamWeaver.Core.Message.text(reply)}")
end
```

## OpenAI-compatible servers

Use `BeamWeaver.OpenAI.chat_completions_model/1` for a server implementing
that contract. Set the exact endpoint, explicit credentials for that server
and a profile describing capabilities you have verified. A server accepting
chat does not necessarily support tools, media or native schema output.

Do not send your configured OpenAI key to a third-party endpoint by accident.
For an unauthenticated local server, the adapter still needs a nonempty
explicit placeholder key. Exercise a real server before claiming its
integration works; an HTTP fixture proves only request/response plumbing.

This executable example uses the real OpenAI Chat Completions endpoint explicitly. For a different compatible server, replace all three of endpoint, credentials and model with that server’s values:

```elixir
model =
  BeamWeaver.OpenAI.chat_completions_model(
    model: "gpt-5.4-mini",
    endpoint: "https://api.openai.com/v1/chat/completions",
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    max_tokens: 128,
    timeout: 60_000
  )

{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Say hello briefly.")
true = byte_size(BeamWeaver.Core.Message.text(reply)) > 0
```

## Adding a provider

Implement the chat, embedding or decision behavior and a `Provider.Adapter`
that resolves its model modules and profiles. Register the adapter at startup
through application configuration or `Provider.Registry`. Each supported
operation needs a real implementation; declaring a prefix or profile does not
create an API capability.

Use provider-native error/outcome contracts, preserve replay-critical content,
and implement streaming cancellation correctly. Test controlled adapter cases
and actual live calls separately. [Testing](testing.md) describes those boundaries.

This complete adapter registers an application prefix and forwards to the actual OpenAI implementation. It demonstrates registry dispatch without inventing a remote model or returning a canned answer:

```elixir
defmodule MyApp.ChatAdapter do
  @behaviour BeamWeaver.Provider.Adapter
  @impl true
  def provider, do: :app_openai
  @impl true
  def chat_model(_opts), do: {:ok, BeamWeaver.OpenAI.ChatModel}
  @impl true
  def profile(id), do: BeamWeaver.Models.ProfileRegistry.fetch(:openai, id)
end

:ok = BeamWeaver.Provider.Registry.register(:app_openai, MyApp.ChatAdapter)

try do
  {:ok, model} = BeamWeaver.Models.init_chat_model("app_openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)
  {:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Say hello briefly.")
  true = byte_size(BeamWeaver.Core.Message.text(reply)) > 0
after
  BeamWeaver.Provider.Registry.unregister(:app_openai)
end
```
