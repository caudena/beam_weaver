# BeamWeaver DeepSeek

BeamWeaver includes a first-class DeepSeek provider for the native Chat
Completions and Responses APIs, plus raw clients for every API surface that
DeepSeek currently publishes.

This guide reflects the DeepSeek documentation checked through 2026-09-10 and the
checked-in live API conformance captures.

## Models

Use explicit provider-prefixed identifiers:

- `deepseek:deepseek-flash` — DeepSeek V4.1 Flash, the default.
- `deepseek:deepseek-v4-flash` and `deepseek:deepseek-v4-flash-vision-exp` — accepted
  compatibility names that now route to V4.1 Flash.
- `deepseek:deepseek-v4-pro` — V4 Pro until its announced September 14,
  2026, 04:00 UTC transition to V4.1 Flash.

All profiles have a 1,048,576-token context window and a maximum output of
393,216 tokens. Both Chat Completions and Responses accept these API IDs.
`deepseek-v4.1-flash` is the release name, not a published API identifier;
use `deepseek-flash`.

Flash accepts JPEG, PNG, GIF, and WebP images: HTTP(S) URLs, base64 data URLs,
and uploaded image `file_id` references. It supports up to 600 images per
request and `low`, `high`, `original`, and `auto` detail. The request body must
fit in 48 MiB, and each inline image must fit in 32 MiB. The provider enforces
remote download, dimensions, and uploaded-file limits. Chat image content can
appear in user/tool messages; Responses also accepts developer messages and
image-bearing tool outputs. System and assistant images are rejected.

FIM remains available in non-thinking mode. V4 Pro is text-only before its
announced redirect; use the canonical Flash ID for new multimodal integrations.

The retired `deepseek-chat` and `deepseek-reasoner` identifiers are not aliases
for the V4 models. BeamWeaver reports them as unsupported so an application
cannot silently change model behavior.

## Configuration

```elixir
config :beam_weaver,
  deepseek: [
    api_key: System.fetch_env!("DEEPSEEK_API_KEY")
  ]
```

`config/runtime.exs` reads `DEEPSEEK_API_KEY`. The stable, beta, and Anthropic
base URLs can also be overridden independently for testing or a compatible
gateway. The default request timeout follows the rest of BeamWeaver's provider
clients: 15 seconds. Set a larger `:timeout` for long reasoning requests.

## Chat Completions

Chat Completions is the default high-level API:

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("deepseek:deepseek-flash",
    thinking: %{type: :enabled},
    reasoning_effort: :low,
    max_tokens: 1_024,
    timeout: 120_000
  )

{:ok, message} =
  BeamWeaver.Core.ChatModel.invoke(model, [
    BeamWeaver.Core.Message.user("Explain OTP supervision in three sentences.")
  ])
```

Thinking output is normalized into reasoning content blocks. When an assistant
tool call is sent back with a tool result, BeamWeaver also replays the
provider's `reasoning_content`, as required by DeepSeek's multi-turn tool
contract.

Chat accepts `none` and `auto` tool choices while thinking. Forced `required`
and named choices require non-thinking mode: use `reasoning_effort: :none` or
`thinking: %{type: "disabled"}`. Canonical effort levels are `low`, `high`, and
`max`; compatibility values `minimal`, `medium`/`xhigh`, and `ultra` map to
`low`, `high`, and `max`. Responses uses `reasoning: %{effort: ...}`.

### Beta endpoint

DeepSeek's beta endpoint is an alternate, unstable API namespace at
`https://api.deepseek.com/beta`. It enables features that DeepSeek has not yet
promoted to its stable endpoint. It is not a different model, a replacement for
the stable API, or an `api:` value in BeamWeaver. The supported `api:` values
remain `:chat_completions` and `:responses`.

BeamWeaver uses the stable Chat endpoint by default and automatically routes a
request to `https://api.deepseek.com/beta/chat/completions` when it contains
either:

- a final assistant message with prefix completion enabled; or
- strict function tools.

To try the beta Chat endpoint for any high-level request, pass `beta: true` as
an invocation option. The same option works with `invoke`, `stream`,
`stream_response`, and the typed-event stream functions:

```elixir
{:ok, message} =
  BeamWeaver.Core.ChatModel.invoke(model, messages, beta: true)
```

The raw Chat client accepts the same per-call option:

```elixir
{:ok, response} =
  BeamWeaver.DeepSeek.Client.chat_completions(client, body, beta: true)
```

To route every Chat request from one model through beta, set its endpoint
explicitly:

```elixir
model =
  BeamWeaver.DeepSeek.chat_model(
    endpoint: "https://api.deepseek.com/beta/chat/completions"
  )
```

`beta_endpoint:` and `DEEPSEEK_BETA_BASE_URL` only change where beta-selected
requests are sent, which is useful for gateways and tests. They do not activate
beta for otherwise stable requests. An explicit per-call `endpoint:` takes
precedence over `beta: true` and automatic feature detection.

FIM completion already uses `https://api.deepseek.com/beta/completions`, so its
raw client methods do not need `beta: true`. The Responses API has no beta route
in BeamWeaver and continues to use the stable `/responses` endpoint.

DeepSeek Chat supports JSON object mode, not native JSON Schema mode.
Schema-shaped BeamWeaver structured-output requests therefore enable
`json_object`, add an explicit JSON/schema instruction, and validate the final
object locally.

## Responses API

Select the stateless Responses API explicitly:

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("deepseek:deepseek-flash",
    api: :responses,
    timeout: 120_000
  )
```

Responses supports the current Flash and Pro profiles, native JSON Schema output, function tools,
server-side web search, and the custom `apply_patch` tool used by DeepSeek's
Codex integration. Its reasoning effort accepts `none`, `minimal`, `low`,
`medium`, `high`, `xhigh`, and `max`; the compatibility values map to the
provider's low/high effort levels. DeepSeek does not store Responses or
conversations: send the complete history on every turn. BeamWeaver rejects
stateful response/conversation parameters. Flash accepts the documented image
parts; audio, video, and general file inputs remain unsupported. Represent
uploaded image references as `ContentBlock.image(file_id: "file-api-...")`.

Current live Responses output can include an opaque `encrypted_content` handle,
with or without plain `reasoning_text` content. BeamWeaver preserves that handle
and any plain reasoning when replaying the terminal assistant message. It does
not interpret the handle or replace it with an ID generated locally.


Hosted web search can complete without an assistant message. The normalized
result preserves reasoning, function-call, web-search, failure, and unknown
output items in response metadata rather than assuming every successful
response contains text.

## Raw Client

`BeamWeaver.DeepSeek.Client` exposes map-in/map-out access to all current
DeepSeek endpoints:

- `chat_completions/3`, streaming deltas, typed events, and collected response
- `responses/3`, streaming deltas/events, and collected response
- `completions/3` for beta FIM, including lazy and collected streams
- `models/2`
- `balance/2`
- `anthropic_messages/3`, including lazy and collected streams

Native endpoints use Bearer authentication. The Anthropic-compatible endpoint
uses `x-api-key` at `https://api.deepseek.com/anthropic/v1/messages` and reuses
BeamWeaver's Anthropic message and stream translation without exposing an
unsupported count-tokens call.

The Anthropic compatibility API accepts canonical DeepSeek IDs. It also maps
Claude model names: `claude-opus*` to Pro and `claude-sonnet*`/`claude-haiku*`
to Flash. Other unsupported names are mapped by the server to Flash; the raw
client preserves that server behavior.

## Streaming And Headers

Chat and FIM return data-only SSE terminated by `[DONE]`. Responses and
Anthropic use named events and their own terminal events. Typed streams emit deltas as they arrive and accumulate the final assistant
message so IDs, complete reasoning, usage, and provider metadata survive the
next tool-result request. Collected stream methods buffer the response.

DeepSeek's `x-ds-trace-id` header is normalized into request metadata.
Synchronous and collected calls accept `include_response_headers: true` to
retain both a normalized header map and the original ordered,
duplicate-preserving header list. Lazy calls accept an `on_response` callback
for transport status and headers without buffering the stream. Missing
rate-limit headers are valid.

## Usage And Pricing

DeepSeek reports prompt cache hits and misses. BeamWeaver normalizes cached and
uncached input, output, total, and reasoning token details, then calculates
cost from the model profile. Reasoning tokens are already included in output
tokens and are never charged twice.

Current prices per one million tokens:

| Model | Mode | Cached input | Uncached input | Output |
| --- | --- | ---: | ---: | ---: |
| `deepseek-flash` and Flash compatibility names | Off-peak | $0.003 | $0.15 | $0.60 |
| `deepseek-flash` and Flash compatibility names | Peak | $0.006 | $0.30 | $1.20 |
| `deepseek-v4-pro` before its redirect | Off-peak | $0.022 | $0.66 | $1.98 |
| `deepseek-v4-pro` before its redirect | Peak | $0.044 | $1.32 | $3.96 |

Flash prices took effect at 04:00 UTC on September 10, 2026. Pro switches to
Flash rates at 04:00 UTC on September 14, 2026. Peak pricing applies Monday
through Friday during 01:00–04:00 and 06:00–10:00 UTC; starts are inclusive,
ends exclusive, and weekends are off-peak. Costs use the response timestamp
and dated profile pricing history. Without a timestamp, the estimator uses
current canonical off-peak rates.

The published account concurrency limits are 2,500 for Flash and 500 for Pro.
They are profile metadata, not an in-process limiter, because DeepSeek enforces
them at account scope across all API keys.

## Errors And Retries

DeepSeek HTTP failures are normalized into authentication, insufficient
balance, invalid request/parameter, rate limit, server error, and overload
categories. JSON errors are decoded even when the server labels the body as
`application/octet-stream`.

The client does not retry automatically. Apply BeamWeaver retry or fallback
middleware at the application boundary where idempotency and provider fallback
policy are explicit.

## Live validation on September 10, 2026

The live `/models` response listed `deepseek-flash` and `deepseek-v4-pro`.
The following bounded checks completed against the official API:

| Model | API | Verified behavior |
| --- | --- | --- |
| V4.1 Flash | Chat Completions and Responses | Image input, image tool results, structured output, 128-character function names, and a streaming model → local tool → model cycle |
| V4 Pro | Chat Completions and Responses | Streaming tool cycle with complete reasoning replay and one final assistant message per turn |
| Legacy Flash / Vision names | Chat / Responses respectively | Accepted and reported `deepseek-flash` as the served model |
| V4.1 Flash | FIM / Anthropic compatibility | Code completion / basic message response |

Streaming checks required a real local multiplication tool to return `391`,
inspected the next serialized request, and checked reasoning, call correlation,
provider metadata, usage, and duplicate assistant messages. These are API
integration checks, not model-quality benchmarks or coverage of every parameter
combination. Deterministic tests cover the same Chat/Responses round trips,
image validation, and pricing boundaries without credentials.

## References

- [V4.1 Flash release and alias transitions](https://api-docs.deepseek.com/news/news260910/)
- [Vision input formats and limits](https://api-docs.deepseek.com/guides/vision/)

- [DeepSeek models and pricing](https://api-docs.deepseek.com/quick_start/pricing/)
- [Chat Completions API](https://api-docs.deepseek.com/api/create-chat-completion/)
- [Chat Prefix Completion](https://api-docs.deepseek.com/guides/chat_prefix_completion/)
- [Strict Function Calling](https://api-docs.deepseek.com/guides/tool_calls/)
- [Responses API guide](https://api-docs.deepseek.com/guides/responses_api/)
- [Responses API reference](https://api-docs.deepseek.com/api/create-response/)
- [FIM Completion API](https://api-docs.deepseek.com/api/create-completion/)
- [Anthropic compatibility](https://api-docs.deepseek.com/guides/anthropic_api/)
- [Rate limit and isolation](https://api-docs.deepseek.com/quick_start/rate_limit/)

The opt-in full-surface runner is
[`scripts/capture_deepseek_live.exs`](../../scripts/capture_deepseek_live.exs).
