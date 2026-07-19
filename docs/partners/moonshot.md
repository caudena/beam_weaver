# BeamWeaver Moonshot/Kimi

BeamWeaver includes an OpenAI-compatible Moonshot provider under
`BeamWeaver.Moonshot` for Kimi chat models.

## Implemented

- `BeamWeaver.Moonshot.ChatModel` implements Moonshot Chat Completions through
  `BeamWeaver.Core.ChatModel`.
- Model initialization uses explicit Moonshot identifiers:
  `BeamWeaver.Models.init_chat_model("moonshot:kimi-k3")`.
- Bare `kimi-*` and `kimi:*` identifiers are rejected so provider routing stays
  explicit.
- Defaults load from `config :beam_weaver, :moonshot`; runtime config reads
  `MOONSHOT_API_KEY` and optional `MOONSHOT_BASE_URL` or `MOONSHOT_API_URL`.
- Chat requests support text, image, and video input; `data:` media URLs and
  Moonshot `ms://...` media references are accepted.
- K3 always reasons and uses the top-level `reasoning_effort: "max"` option;
  it rejects the K2.x `thinking` object. K2.7 Code models
  require thinking to stay enabled; K2.6 and K2.5 accept
  `thinking: %{type: "enabled" | "disabled"}`. `reasoning_content` is
  preserved in message content blocks and normalized response metadata.
- Standard function tools use the OpenAI-compatible `tools` shape. K3 accepts
  `tool_choice: "required"` and dynamically loaded tools through contentless
  system messages created by `BeamWeaver.Moonshot.Tools.dynamic_message/1`.
  Kimi `$web_search` is available through
  `BeamWeaver.Moonshot.Tools.web_search/1` on K2.6/K2.5 and requires
  `thinking: %{type: "disabled"}`.
- Structured output supports `json_object` and `json_schema` response formats.
- Partial mode is emitted from assistant message metadata `partial: true`; JSON
  object mode with partial mode fails before transport.
- Streaming supports text deltas, reasoning deltas, tool-call chunks, usage
  nested under either the response or final choice, reconstructed final
  assistant messages, and typed stream events.
- Token counting uses `/v1/tokenizers/estimate-token-count`.
- Checked-in profiles include `kimi-k3`, `kimi-k2.7-code`,
  `kimi-k2.7-code-highspeed`, `kimi-k2.6`, and `kimi-k2.5`; discontinued Kimi
  slugs fail before transport with K3 replacement metadata.

## Usage

```elixir
model =
  BeamWeaver.Moonshot.chat_model(
    model: "kimi-k3",
    reasoning_effort: "max"
  )

BeamWeaver.Core.ChatModel.invoke(model, [
  BeamWeaver.Core.Message.user("Summarize the trace.")
])
```

Use model-string routing when constructing through the generic initializer:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("moonshot:kimi-k3")
```

Require a tool call on K3:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, messages,
  tool_choice: :required,
  tools: [weather_tool]
)
```

Dynamically load a tool at a specific point in K3 conversation history:

```elixir
messages = [
  BeamWeaver.Core.Message.user("Calculate 23 * 47"),
  BeamWeaver.Moonshot.Tools.dynamic_message([calculator_tool])
]

BeamWeaver.Core.ChatModel.invoke(model, messages)
```

Use Kimi web search with a K2.6/K2.5 model and thinking disabled:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("moonshot:kimi-k2.6")

BeamWeaver.Core.ChatModel.invoke(model, messages,
  thinking: %{type: "disabled"},
  tools: [BeamWeaver.Moonshot.Tools.web_search()]
)
```

## Current Model Policy

`kimi-k3`, `kimi-k2.7-code`, `kimi-k2.7-code-highspeed`, `kimi-k2.6`, and
`kimi-k2.5` are supported Moonshot profiles. K3 has a 1,048,576-token context
window, a 131,072-token default completion limit, and a 1,048,576-token maximum
completion limit. It always reasons, currently accepts only
`reasoning_effort: "max"`, supports `tool_choice` values `auto`, `none`, and
`required`, and is the only Kimi model that accepts dynamic tool messages.
K2.7 Code models are thinking-only and accept only
automatic tool choice (`"auto"` or `"none"`) while thinking is enabled. K2.6 and
K2.5 support both thinking and non-thinking modes; fixed sampling values are
validated before transport.

K3 accepts text plus base64 or `ms://` image/video input, streaming, parallel
function calls, JSON object mode, strict JSON Schema output, Partial Mode,
automatic prefix caching, prompt cache keys, safety identifiers, and token
estimation. Sampling is fixed at `temperature=1.0`, `top_p=0.95`, `n=1`, and
zero presence/frequency penalties. Complete assistant messages, including
`reasoning_content` and `tool_calls`, must be replayed unchanged in later turns.

Older Kimi slugs such as
`kimi-latest`, `kimi-thinking-preview`, `kimi-k2-0905-preview`,
`kimi-k2-0711-preview`, `kimi-k2-turbo-preview`, `kimi-k2-thinking`, and
`kimi-k2-thinking-turbo` are rejected with `:deprecated_model` and
`moonshot:kimi-k3` as the replacement. K2.5 is unavailable to newly registered
Kimi users and is scheduled for full sunset on August 31, 2026.

Moonshot Files, Batch, Balance, and Formula/Fiber tool APIs are not exposed in
BeamWeaver yet. Chat can still reference provider-hosted media with documented
`ms://...` image or video URLs.

Kimi currently marks its web-search integration as being updated and advises
against near-term production use. BeamWeaver therefore keeps the legacy
`$web_search` helper limited to models where thinking can be disabled and does
not advertise it as a K3 capability.

## Related Guides

- [Models](../models.md)
- [Prompt Caching](../prompt_caching.md#moonshotkimi)
- [Tools](../tools.md#server-side-provider-tools)
- [Structured Output](../structured_output.md)
- [Messages](../messages.md)
