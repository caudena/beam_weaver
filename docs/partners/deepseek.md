# BeamWeaver DeepSeek

BeamWeaver includes a first-class DeepSeek provider for the native Chat
Completions and Responses APIs, plus raw clients for every API surface that
DeepSeek currently publishes.

This guide reflects the DeepSeek documentation and live API behavior checked
on 2026-08-02.

## Models

Use explicit provider-prefixed identifiers:

- `deepseek:deepseek-v4-flash`
- `deepseek:deepseek-v4-pro`

Both models have a 1,048,576-token context window and a maximum output of
393,216 tokens. Chat Completions supports both models. The Responses API
currently supports only `deepseek-v4-flash`; BeamWeaver rejects a Pro
Responses request before making an HTTP request.

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
  BeamWeaver.Models.init_chat_model("deepseek:deepseek-v4-flash",
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

Current V4 behavior rejects any explicit Chat `tool_choice` while thinking is
active, including `none`, `auto`, and `required`. Omit `tool_choice` to let a
thinking model select from declared tools, or set
`thinking: %{type: "disabled"}` before sending an explicit choice. For
Responses, forced function/custom choices require
`reasoning: %{effort: "none"}`; automatic choice and hosted web search remain
available with reasoning.

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
  BeamWeaver.Models.init_chat_model("deepseek:deepseek-v4-flash",
    api: :responses,
    timeout: 120_000
  )
```

Responses supports native JSON Schema output, function tools, server-side web
search, and the custom `apply_patch` tool used by DeepSeek's Codex integration.
DeepSeek does not store Responses or conversations: send the complete history
on every turn. BeamWeaver rejects stateful response/conversation parameters and
unsupported image, audio, video, or file inputs instead of allowing the server
to replace them with placeholder text.

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
Anthropic use named events and their own terminal events. All BeamWeaver lazy
stream methods remain lazy and do not buffer the potentially large response.
Collected stream methods necessarily reconstruct the full response in memory.

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

| Model | Cached input | Uncached input | Output |
| --- | ---: | ---: | ---: |
| `deepseek-v4-flash` | $0.0028 | $0.14 | $0.28 |
| `deepseek-v4-pro` | $0.003625 | $0.435 | $0.87 |

The published account concurrency limits are 2,500 for Flash and 500 for Pro.
They are profile metadata, not an in-process limiter, because DeepSeek enforces
them at account scope across all API keys.

DeepSeek has announced a future 2x peak-hours multiplier but has not announced
its effective date. BeamWeaver records the policy in metadata and documentation
without applying it to calculated costs yet.

## Errors And Retries

DeepSeek HTTP failures are normalized into authentication, insufficient
balance, invalid request/parameter, rate limit, server error, and overload
categories. JSON errors are decoded even when the server labels the body as
`application/octet-stream`.

The client does not retry automatically. Apply BeamWeaver retry or fallback
middleware at the application boundary where idempotency and provider fallback
policy are explicit.

## References

- [DeepSeek models and pricing](https://api-docs.deepseek.com/quick_start/pricing/)
- [Chat Completions API](https://api-docs.deepseek.com/api/create-chat-completion/)
- [Chat Prefix Completion](https://api-docs.deepseek.com/guides/chat_prefix_completion/)
- [Strict Function Calling](https://api-docs.deepseek.com/guides/tool_calls/)
- [Responses API](https://api-docs.deepseek.com/api/create-response/)
- [FIM Completion API](https://api-docs.deepseek.com/api/create-completion/)
- [Anthropic compatibility](https://api-docs.deepseek.com/guides/anthropic_api/)
- [Rate limit and isolation](https://api-docs.deepseek.com/quick_start/rate_limit/)

The opt-in full-surface runner is
[`scripts/capture_deepseek_live.exs`](../../scripts/capture_deepseek_live.exs).
