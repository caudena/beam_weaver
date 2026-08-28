# BeamWeaver xAI

BeamWeaver includes an OpenAI-compatible xAI provider under `BeamWeaver.XAI`.
This guide reflects the xAI model catalog and pricing documentation checked on
2026-08-12.

## Implemented

- `BeamWeaver.XAI.ChatModel` implements the xAI Responses API through
  `BeamWeaver.Core.ChatModel`.
- `BeamWeaver.XAI.ChatCompletionsModel` implements the xAI Chat Completions API.
- `BeamWeaver.XAI.EmbeddingModel` implements the xAI Embeddings API with model
  `v1`.
- `BeamWeaver.XAI.Tools` renders custom OpenAI-compatible function tools and
  passes through xAI built-ins such as `web_search`, `x_search`,
  `code_execution`, `code_interpreter`, `attachment_search`,
  `collections_search`, `file_search`, `shell`, `view_image`, `view_x_video`,
  `live_search`, and `mcp`.
- Namespace constructors load defaults from `config :beam_weaver, :xai`; put
  any OS environment reads in your `config/runtime.exs`. Custom routing can use
  configured `:base_url`, explicit `:base_url`, or `:endpoint`.
- Responses include normalized provider metadata, reasoning content, citations,
  usage metadata, and xAI-specific reasoning-token accounting.
- Streaming supports text and reasoning deltas, reconstructed final assistant
  messages, and typed stream envelopes tagged with xAI invocation metadata.
- xAI chat profiles expose `tool_call_streaming: true` when the checked-in
  profile supports incremental streamed tool-call arguments.
- Chat Completions streaming preserves empty initial role-only chunks,
  incremental tool argument deltas, final assistant tool calls, finish reasons,
  and detailed usage metadata.
- Structured output is available on both Responses and Chat Completions. xAI
  request rendering keeps dynamic map fields as open object schemas while
  preserving strict closed-object validation for normal nested objects.
- Reasoning profiles omit unsupported `stop` request parameters at the xAI
  provider boundary. Non-reasoning chat-completions models keep supported
  `stop` sequences.
- Deferred Chat Completions requests can be followed up with
  `BeamWeaver.XAI.Client.deferred_completion/3`.
- Checked-in chat profiles cover `grok-4.6`, `grok-4.5`, `grok-4.3`,
  `grok-4.20-0309-reasoning`, `grok-4.20-0309-non-reasoning`,
  `grok-4.20-multi-agent-0309`, and `grok-build-0.1`, with alias handling for
  documented xAI slugs.
- Retired May 15, 2026 slugs fail before transport with replacement metadata
  instead of silently changing price or reasoning behavior.

## Usage

```elixir
model =
  BeamWeaver.XAI.chat_model(
    model: "grok-4.6"
  )

BeamWeaver.Core.ChatModel.invoke(model, [
  BeamWeaver.Core.Message.user("Summarize what makes the BEAM good for agents.")
])
```

Use Chat Completions explicitly when that wire shape is required:

```elixir
model =
  BeamWeaver.XAI.chat_completions_model(
    model: "grok-4.6"
  )
```

Tools are provider request values:

```elixir
tools = [
  BeamWeaver.XAI.Tools.web_search(search_depth: :deep),
  BeamWeaver.XAI.Tools.x_search(),
  BeamWeaver.XAI.Tools.code_execution(),
  BeamWeaver.XAI.Tools.function(my_tool, strict: true)
]

BeamWeaver.Core.ChatModel.invoke(model, messages, tools: tools)
```

Use `BeamWeaver.XAI.Tools.live_search/1` for Chat Completions search tools.

Model initialization can use explicit or inferred xAI identifiers:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("xai:grok-4.6")
{:ok, model} = BeamWeaver.Models.init_chat_model("xai:grok-4.20-0309-reasoning")
```

Embeddings use the explicit xAI prefix:

```elixir
{:ok, embeddings} = BeamWeaver.Models.init_embeddings("xai:v1")
{:ok, vector} = BeamWeaver.Core.EmbeddingModel.embed_query(embeddings, "hello")
```

## Grok 4.6

xAI recommends `grok-4.6` for general use, including coding, and BeamWeaver now
uses it as the default xAI chat model. The checked-in profile records both the
Responses and Chat Completions APIs, a 500,000-token context window, text and
image input, text output, function calling, structured output, streaming, a
February 1, 2026 knowledge cutoff, and `low`, `medium`, `high`, and `xhigh`
reasoning effort. `high` is the default. xAI publishes no text-output limit for
this model, so the profile leaves `max_output_tokens` unset and records
`text_output_limit: :unlimited` explicitly.

The checked-in Grok 4.6 profile accepts `low`, `medium`, and `high` reasoning
effort. `xhigh` is not advertised for that model and is rejected by profile
validation.

The current xAI catalog does not publish a `grok-4.6-latest` or
`grok-4.6-fast` model ID. Use the exact `grok-4.6` identifier. Existing aliases
remain mapped to the canonical models xAI currently lists; in particular,
`grok-4.5-latest` and `grok-build-latest` remain Grok 4.5 aliases, while
`grok-latest` remains a Grok 4.3 alias.

Standard prices per million tokens are:

| Model | Context tier | Input | Cached input | Output |
| --- | --- | ---: | ---: | ---: |
| `grok-4.6` | Under 200k input tokens | $2.00 | $0.50 | $6.00 |
| `grok-4.6` | 200k tokens or more | $4.00 | $1.00 | $12.00 |
| `grok-4.5` | Under 200k input tokens | $2.00 | $0.30 | $6.00 |
| `grok-4.5` | 200k tokens or more | $4.00 | $0.60 | $12.00 |

The checked-in Grok 4.20 reasoning, non-reasoning, multi-agent, and Grok Build
profiles also record their published higher-context rates at the 200k-token
threshold. The `xai:v1` embedding profile intentionally records that no public
price was listed when the catalog was checked; BeamWeaver does not invent one.

Once input reaches the 200k threshold, xAI applies the higher rates to all
request tokens. Priority processing is selected with
`service_tier: :priority` on either supported API and costs twice the applicable
standard rate; it is not a different model. Hosted tool calls are billed
separately: web search, X search, and code execution cost $5 per 1,000 calls,
attachment search costs $10 per 1,000 calls, and collections/file search costs
$2.50 per 1,000 calls. See the official [Grok 4.6 model
card](https://docs.x.ai/developers/models/grok-4.6), [model
catalog](https://docs.x.ai/developers/models), and [xAI API
pricing](https://docs.x.ai/developers/pricing).

BeamWeaver keeps profiles for the other current chat models listed above, plus
embedding model `v1`. Imagine and voice models are not chat or embedding models
and are not constructed through `init_chat_model/2`.

Reasoning profiles can still be invoked with shared model options from a generic
caller. If those options include `stop`, BeamWeaver removes it only for xAI
reasoning request shapes, avoiding provider-side request rejection without
changing caller data for other providers or non-reasoning xAI chat models.

The retired May 15, 2026 slugs are rejected with `:deprecated_model`:
`grok-4-1-fast-reasoning`, `grok-4-1-fast-non-reasoning`,
`grok-4-fast-reasoning`, `grok-4-fast-non-reasoning`, `grok-4-0709`,
`grok-code-fast-1`, `grok-3`, and `grok-imagine-image-pro`.

## Unsupported xAI Surfaces

- xAI image/video generation APIs. LangChain's xAI partner currently exposes
  chat behavior; BeamWeaver does not expose image/video provider APIs.
- Exact Python class identity and serialization compatibility. BeamWeaver keeps
  native Elixir modules, structs, and tagged errors.
