# BeamWeaver Z.ai

BeamWeaver includes a Z.ai provider under `BeamWeaver.ZAI` for GLM-5.3,
GLM-5.3-Flash, and GLM-5.2 Chat Completions.

## Surface

- `BeamWeaver.ZAI.ChatModel` implements `BeamWeaver.Core.ChatModel`.
- `BeamWeaver.ZAI.Client` calls
  `https://api.z.ai/api/paas/v4/chat/completions` by default.
- Model initialization is strict: use `zai:glm-5.3`, `zai:glm-5.3-flash`, or
  `zai:glm-5.2`. Bare `glm-*` identifiers and other `zai:*` models are rejected
  before transport.
- Runtime config uses `config :beam_weaver, :zai`; `runtime.exs` reads
  `ZAI_API_KEY` plus optional `ZAI_BASE_URL` or `ZAI_API_URL`.
- Standard function tools are rendered as OpenAI-compatible Chat Completions
  `tools`. Z.ai `tool_stream: true` is supported for streaming tool-call
  argument chunks and requires `stream: true`.
- Structured output uses JSON object mode:
  `response_format: %{type: "json_object"}`. BeamWeaver schema requests are
  mapped to JSON object mode, the schema is injected as provider-visible
  instructions, and the response is parsed and validated locally. JSON Schema
  request mode is not enabled for this provider.
- Streaming reconstructs text, reasoning content, streamed tool-call chunks,
  final usage chunks, and `finish_reason: "length"` truncation.
- Usage metadata tracks prompt, completion, total, cached input, and reasoning
  output tokens. Cost metadata uses the selected profile's checked-in prices
  and does not double-bill reasoning tokens.
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
  BeamWeaver.Models.init_chat_model("zai:glm-5.3",
    reasoning_effort: :high,
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

## Profiles

All three profiles are checked in with:

- 1,000,000 input tokens
- 131,072 maximum output tokens
- text input and output
- reasoning output
- function tools
- JSON object mode
- streaming
- usage metadata
- Chat Completions API only

GLM-5.3 and GLM-5.3-Flash always use thinking and accept `low`, `high`, and
`max` reasoning effort; `max` is the default. GLM-5.2 retains the broader
compatibility effort ladder and supports enabled or disabled thinking.

GLM-5.3-Flash additionally accepts native image, video, and PDF inputs and
attachment content. The other two profiles are text-input models.

Current cost metadata per one million tokens:

| Model | Input | Cached input | Output |
| --- | ---: | ---: | ---: |
| `glm-5.3` | $1.40 | $0.26 | $4.40 |
| `glm-5.3-flash` promotional | $0.075 | $0.015 | $0.25 |
| `glm-5.3-flash` regular | $0.15 | $0.03 | $0.50 |
| `glm-5.2` | $1.40 | $0.26 | $4.40 |

The GLM-5.3-Flash promotional rates are recorded through
`2026-09-09T24:00:00+08:00`; regular rates remain in the profile so accounting
can switch at the explicit boundary rather than guessing.

## Unsupported Z.ai Surfaces

- Z.ai models outside the three explicit IDs above are intentionally not routed.
- JSON Schema request mode is not enabled until live or documented support is
  clear for this endpoint.
- Built-in tools and non-chat APIs are not exposed in BeamWeaver. Media input is
  limited to the GLM-5.3-Flash profile.
