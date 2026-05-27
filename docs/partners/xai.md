# BeamWeaver xAI

BeamWeaver includes an OpenAI-compatible xAI provider under `BeamWeaver.XAI`.

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
- Streaming supports text deltas, reconstructed final assistant messages, and
  typed stream envelopes tagged with xAI invocation metadata.
- Deferred Chat Completions requests can be followed up with
  `BeamWeaver.XAI.Client.deferred_completion/3`.
- Checked-in chat profiles cover `grok-4.3`, `grok-4.20-0309-reasoning`,
  `grok-4.20-0309-non-reasoning`, `grok-4.20-multi-agent-0309`, and
  `grok-build-0.1`, with alias handling for documented xAI slugs.
- Retired May 15, 2026 slugs fail before transport with replacement metadata
  instead of silently changing price or reasoning behavior.

## Usage

```elixir
model =
  BeamWeaver.XAI.chat_model(
    model: "grok-4.3"
  )

BeamWeaver.Core.ChatModel.invoke(model, [
  BeamWeaver.Core.Message.user("Summarize what makes the BEAM good for agents.")
])
```

Use Chat Completions explicitly when that wire shape is required:

```elixir
model =
  BeamWeaver.XAI.chat_completions_model(
    model: "grok-4.3"
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
{:ok, model} = BeamWeaver.Models.init_chat_model("xai:grok-4.3")
{:ok, model} = BeamWeaver.Models.init_chat_model("xai:grok-4.20-0309-reasoning")
```

Embeddings use the explicit xAI prefix:

```elixir
{:ok, embeddings} = BeamWeaver.Models.init_embeddings("xai:v1")
{:ok, vector} = BeamWeaver.Core.EmbeddingModel.embed_query(embeddings, "hello")
```

## Current Model Policy

xAI recommends `grok-4.3` for most chat and coding use cases. BeamWeaver keeps
profiles for the other current chat models listed above, plus embedding model
`v1`. Imagine and voice models are not chat or embedding models and are not
constructed through `init_chat_model/2`.

The retired May 15, 2026 slugs are rejected with `:deprecated_model`:
`grok-4-1-fast-reasoning`, `grok-4-1-fast-non-reasoning`,
`grok-4-fast-reasoning`, `grok-4-fast-non-reasoning`, `grok-4-0709`,
`grok-code-fast-1`, `grok-3`, and `grok-imagine-image-pro`.

## Remaining xAI Work

- Live-cassette expansion against the xAI API once credentials and stable
  fixtures are available.
- xAI image/video generation APIs. LangChain's xAI partner currently exposes
  chat behavior; BeamWeaver does not expose image/video provider APIs.
- Exact Python class identity and serialization compatibility. BeamWeaver keeps
  native Elixir modules, structs, and tagged errors.

## Related Guides

- [Models](../models.md)
- [Tools](../tools.md#server-side-provider-tools)
- [Structured Output](../structured_output.md)
- [Messages](../messages.md)
