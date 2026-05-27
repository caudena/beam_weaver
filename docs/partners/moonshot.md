# BeamWeaver Moonshot/Kimi

BeamWeaver includes an OpenAI-compatible Moonshot provider under
`BeamWeaver.Moonshot` for Kimi chat models.

## Implemented

- `BeamWeaver.Moonshot.ChatModel` implements Moonshot Chat Completions through
  `BeamWeaver.Core.ChatModel`.
- Model initialization uses explicit Moonshot identifiers:
  `BeamWeaver.Models.init_chat_model("moonshot:kimi-k2.6")`.
- Bare `kimi-*` and `kimi:*` identifiers are rejected so provider routing stays
  explicit.
- Defaults load from `config :beam_weaver, :moonshot`; runtime config reads
  `MOONSHOT_API_KEY` and optional `MOONSHOT_BASE_URL` or `MOONSHOT_API_URL`.
- Chat requests support text, image, and video input; `data:` media URLs and
  Moonshot `ms://...` media references are accepted.
- Kimi K2.6 thinking is exposed through `thinking: %{type: "enabled" | "disabled"}`.
  `reasoning_content` is preserved in message content blocks and normalized
  response metadata.
- Standard function tools use the OpenAI-compatible `tools` shape. Kimi
  `$web_search` is available through `BeamWeaver.Moonshot.Tools.web_search/1`
  and requires `thinking: %{type: "disabled"}`.
- Structured output supports `json_object` and `json_schema` response formats.
- Partial mode is emitted from assistant message metadata `partial: true`; JSON
  object mode with partial mode fails before transport.
- Streaming supports text deltas, reasoning deltas, tool-call chunks, usage
  chunks, reconstructed final assistant messages, and typed stream events.
- Token counting uses `/v1/tokenizers/estimate-token-count`.
- Checked-in profiles include `kimi-k2.6`; discontinued Kimi slugs fail before
  transport with replacement metadata.

## Usage

```elixir
model =
  BeamWeaver.Moonshot.chat_model(
    model: "kimi-k2.6"
  )

BeamWeaver.Core.ChatModel.invoke(model, [
  BeamWeaver.Core.Message.user("Summarize the trace.")
])
```

Use model-string routing when constructing through the generic initializer:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("moonshot:kimi-k2.6")
```

Use Kimi web search with thinking disabled:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, messages,
  thinking: %{type: "disabled"},
  tools: [BeamWeaver.Moonshot.Tools.web_search()]
)
```

## Current Model Policy

`kimi-k2.6` is the supported Moonshot profile. Older Kimi slugs such as
`kimi-latest`, `kimi-thinking-preview`, `kimi-k2-0905-preview`,
`kimi-k2-0711-preview`, `kimi-k2-turbo-preview`, `kimi-k2-thinking`, and
`kimi-k2-thinking-turbo` are rejected with `:deprecated_model` and
`moonshot:kimi-k2.6` as the replacement.

Moonshot Files, Batch, Balance, and Formula/Fiber tool APIs are not exposed in
BeamWeaver yet. Chat can still reference provider-hosted media with documented
`ms://...` image or video URLs.

## Related Guides

- [Models](../models.md)
- [Tools](../tools.md#server-side-provider-tools)
- [Structured Output](../structured_output.md)
- [Messages](../messages.md)
