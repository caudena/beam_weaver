# Prompt Caching

Prompt caching lets a provider reuse the stable prefix of a request, usually the
long system prompt and shared instructions. BeamWeaver keeps this provider-owned
control explicit because each model API exposes different cache knobs and
different usage metadata.

Use prompt caching when a flow repeatedly sends the same long prompt:

- report or analysis agents with a large policy book
- support agents with a stable procedure manual
- chat agents with long static instructions
- extraction agents that run the same schema and instructions over many inputs

Do not include per-user, per-thread, or per-record data in the cache identity
unless you intentionally want separate cache buckets. The provider still hashes
the request prefix, but stable keys help providers route equivalent requests to
the same cache entry when they support explicit keys.

## Stable Cache Keys

Build keys from the stable prompt, provider/model, and a version you control.
Change the version when the static prompt changes semantically.

```elixir
defmodule MyApp.PromptCache do
  @version "v1"

  def key(scope, provider_model, static_prompt) do
    digest =
      static_prompt
      |> then(fn prompt -> :crypto.hash(:sha256, prompt) end)
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 18)

    "my_app:prompt-cache:#{@version}:#{scope}:#{provider_model}:#{digest}"
  end
end
```

This scope is deliberately about the static prompt, not the current user,
thread, project, or record. That lets repeated reports or chats share cache hits
while the provider keeps correctness tied to the actual request prefix.

## OpenAI Responses

OpenAI Responses supports `:prompt_cache_key`. The same static prompt plus the
same key is what makes the second and later calls eligible for reuse.

```elixir
alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message

system_prompt = MyApp.Prompts.support_policy()
cache_key = MyApp.PromptCache.key("support-agent", "openai:gpt-5.4-mini", system_prompt)

model =
  BeamWeaver.OpenAI.ChatModel.new(
    model: "gpt-5.4-mini",
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    prompt_cache_key: cache_key,
    prompt_cache_retention: :in_memory
  )

messages = [
  Message.system(system_prompt),
  Message.user("Ticket SUP-42: can deleted exports be restored?")
]

{:ok, first} = ChatModel.invoke(model, messages)
{:ok, second} = ChatModel.invoke(model, messages)
```

When the provider reports a hit, BeamWeaver preserves it in
`response.usage_metadata.input_token_details.cache_read`.

## OpenAI Chat Completions

Chat Completions uses the same BeamWeaver option:

```elixir
cache_key = MyApp.PromptCache.key("support-agent", "openai:gpt-5.4-mini", system_prompt)

model =
  BeamWeaver.OpenAI.ChatCompletionsModel.new(
    model: "gpt-5.4-mini",
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    prompt_cache_key: cache_key,
    prompt_cache_retention: :in_memory
  )

{:ok, response} = BeamWeaver.Core.ChatModel.invoke(model, messages)
```

## xAI Grok

xAI Responses accepts `:prompt_cache_key`:

```elixir
cache_key = MyApp.PromptCache.key("support-agent", "xai:grok-4.3", system_prompt)

model =
  BeamWeaver.XAI.ChatModel.new(
    model: "grok-4.3",
    api_key: System.fetch_env!("XAI_API_KEY"),
    prompt_cache_key: cache_key
  )

{:ok, response} = BeamWeaver.Core.ChatModel.invoke(model, messages)
```

xAI Chat Completions uses the `x-grok-conv-id` header. BeamWeaver exposes that
as `:x_grok_conv_id`:

```elixir
cache_key = MyApp.PromptCache.key("support-agent", "xai:grok-4.3", system_prompt)

model =
  BeamWeaver.XAI.ChatCompletionsModel.new(
    model: "grok-4.3",
    api_key: System.fetch_env!("XAI_API_KEY"),
    x_grok_conv_id: cache_key
  )

{:ok, response} = BeamWeaver.Core.ChatModel.invoke(model, messages)
```

Per-call overrides are supported for flows where the model is shared:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, messages, x_grok_conv_id: cache_key)
```

## Anthropic

Anthropic prompt caching is block-based. Use
`BeamWeaver.Agent.Middleware.PromptCaching` on agents with a static system
prompt. BeamWeaver marks the static system prompt with Anthropic
`cache_control`; user messages and tool outputs are not marked by this
middleware.

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model(
    BeamWeaver.Anthropic.ChatModel.new(
      model: "claude-haiku-4-5-20251001",
      api_key: System.fetch_env!("ANTHROPIC_API_KEY")
    )
  )

  middleware do
    use BeamWeaver.Agent.Middleware.PromptCaching
  end

  system_prompt(MyApp.Prompts.support_policy())
end
```

Then call the agent normally. Repeated calls with the same system prompt become
eligible for Anthropic cache reads:

```elixir
input = %{messages: [BeamWeaver.Core.Message.user("Ticket SUP-42 needs review.")]}

{:ok, first_state} = MyApp.SupportAgent.invoke(input)
{:ok, second_state} = MyApp.SupportAgent.invoke(input)
```

## Moonshot/Kimi

Moonshot/Kimi supports `:prompt_cache_key` on chat completions:

```elixir
cache_key = MyApp.PromptCache.key("support-agent", "moonshot:kimi-k2.6", system_prompt)

model =
  BeamWeaver.Moonshot.ChatModel.new(
    model: "kimi-k2.6",
    api_key: System.fetch_env!("MOONSHOT_API_KEY"),
    prompt_cache_key: cache_key
  )

{:ok, response} = BeamWeaver.Core.ChatModel.invoke(model, messages)
```

Kimi usage payloads can report cached tokens as `cached_tokens` or provider
detail fields. BeamWeaver normalizes those into
`response.usage_metadata.input_token_details.cache_read`.

## Google Gemini

Gemini can report implicit cached content through `cachedContentTokenCount`.
BeamWeaver preserves that as `input_token_details.cache_read`.

If you already manage Gemini cached-content resources outside BeamWeaver, pass
the resource name with `:cached_content`:

```elixir
model =
  BeamWeaver.Google.ChatModel.new(
    model: "gemini-3.5-flash",
    api_key: System.fetch_env!("GOOGLE_API_KEY"),
    cached_content: "cachedContents/support-policy-v1"
  )
```

BeamWeaver does not create or expire Gemini cached-content resources for you in
this release.

## Z.ai GLM

Z.ai does not expose a BeamWeaver cache key option in this release. When Z.ai
returns cached-token usage, BeamWeaver still normalizes it to
`input_token_details.cache_read`.

## Inspect Cache Hits

All supported providers normalize cache-read metrics to the same response shape
when the provider returns enough data:

```elixir
cache_read = get_in(response.usage_metadata, [:input_token_details, :cache_read]) || 0
```

With WeaveScope tracing enabled, the same usage metadata is attached to model
spans. WeaveScope displays cached input tokens in the token breakdown so you can
confirm whether repeated calls are actually hitting the provider cache.

## Run The Example

The repository includes a live example that follows the normal BeamWeaver
example convention: `BEAM_WEAVER_EXAMPLES_MODEL` selects the provider/model, and
the matching provider API key is read from the environment.

```bash
export BEAM_WEAVER_EXAMPLES_MODEL=openai:gpt-5.4-mini
mix run examples/prompt_caching.exs
```

The example calls the selected model twice with the same long static prompt and
prints the answer plus provider-reported cached input tokens.
