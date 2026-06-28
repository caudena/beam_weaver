# BeamWeaver Z.ai

BeamWeaver includes a Z.ai provider under `BeamWeaver.ZAI` for GLM-5.2 Chat
Completions.

## Surface

- `BeamWeaver.ZAI.ChatModel` implements `BeamWeaver.Core.ChatModel`.
- `BeamWeaver.ZAI.Client` calls
  `https://api.z.ai/api/paas/v4/chat/completions` by default.
- Model initialization is strict: use `zai:glm-5.2`. Bare `glm-*` identifiers
  and other `zai:*` models are rejected before transport.
- Runtime config uses `config :beam_weaver, :zai`; `runtime.exs` reads
  `ZAI_API_KEY` plus optional `ZAI_BASE_URL` or `ZAI_API_URL`.
- Standard function tools are rendered as OpenAI-compatible Chat Completions
  `tools`. Z.ai `tool_stream: true` is supported for streaming tool-call
  argument chunks and requires `stream: true`.
- Structured output uses JSON object mode:
  `response_format: %{type: "json_object"}`. BeamWeaver schema requests are
  mapped to JSON object mode and parsed locally; JSON Schema request mode is
  not enabled for this provider.
- Streaming reconstructs text, reasoning content, streamed tool-call chunks,
  final usage chunks, and `finish_reason: "length"` truncation.
- Usage metadata tracks prompt, completion, total, cached input, and reasoning
  output tokens. Cost metadata uses the checked-in GLM-5.2 prices and does not
  double-bill reasoning tokens.
- Token counting uses BeamWeaver's approximate fallback.

## Usage

```elixir
config :beam_weaver,
  zai: [
    api_key: System.fetch_env!("ZAI_API_KEY")
  ]
```

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("zai:glm-5.2",
    reasoning_effort: :low,
    thinking: %{type: :enabled},
    max_output_tokens: 1_024
  )

{:ok, message} =
  BeamWeaver.Core.ChatModel.invoke(model, [
    BeamWeaver.Core.Message.user("Reply with a concise plan.")
  ])
```

Stream with usage and tool-call argument chunks:

```elixir
{:ok, message} =
  BeamWeaver.ZAI.ChatModel.stream_response(
    model,
    [BeamWeaver.Core.Message.user("Call get_weather for Tokyo.")],
    tools: [weather_tool],
    tool_choice: "auto",
    tool_stream: true
  )
```

## Profile

`zai:glm-5.2` is checked in with:

- 1,000,000 input tokens
- 131,072 maximum output tokens
- text input and output
- reasoning output
- function tools
- JSON object mode
- streaming
- usage metadata
- Chat Completions API only

GLM-5.2 cost metadata:

- input: `$1.40 / 1M tokens`
- cached input: `$0.26 / 1M tokens`
- output: `$4.40 / 1M tokens`

## Remaining Z.ai Work

- Additional Z.ai models are intentionally not routed yet.
- JSON Schema request mode is not enabled until live or documented support is
  clear for this endpoint.
- Z.ai media, built-in tools, and non-chat APIs are not exposed in BeamWeaver.

## Related Guides

- [Models](../models.md)
- [Prompt Caching](../prompt_caching.md#zai-glm)
