# BeamWeaver Anthropic

BeamWeaver includes a direct Anthropic Messages API provider under
`BeamWeaver.Anthropic`.

## Implemented

- `BeamWeaver.Anthropic.ChatModel` implements `BeamWeaver.Core.ChatModel`.
- `BeamWeaver.Anthropic.Tools` renders custom tools and Anthropic server-side
  tool declarations.
- Requests go through `BeamWeaver.Transport`, so tests can run against fake or
  replay transports without live credentials.
- Anthropic namespace constructors load defaults from `config :beam_weaver,
  :anthropic`; put any OS environment reads in your `config/runtime.exs`.
  Custom routing uses explicit `:endpoint` and `:count_tokens_endpoint` options.
- BeamWeaver messages become Anthropic `messages` plus top-level `system`.
- Tool result messages become user-role `tool_result` blocks.
- Assistant `tool_calls` become Anthropic `tool_use` content blocks.
- Tool-call IDs are normalized at the Anthropic provider boundary. Existing
  Anthropic `toolu_*` IDs are preserved, and cross-provider call IDs are mapped
  deterministically to Anthropic-safe IDs without mutating BeamWeaver's native
  message structs.
- Text, image, file/document, thinking, redacted thinking, citations, server tool
  calls/results, and unknown provider blocks are preserved where possible.
- Responses become assistant messages with normalized usage metadata, cache
  token details, response metadata, and extracted tool calls.
- Streaming SSE bodies are parsed into text deltas, lifecycle events, typed
  stream envelopes, and reconstructed final assistant messages. Signed thinking
  deltas and fragmented tool inputs retain their block state across transport
  batches; signed thinking is assembled into one provider-faithful replay block.
- The token counting endpoint is exposed through `ChatModel.count_tokens/3`.
- Checked-in model profiles cover Claude Fable 5.1, Claude Mythos 5.1, Claude
  Opus 5, Claude Sonnet 5, Claude Fable 5, Claude Mythos 5, current Claude
  Opus 4.8/4.7/4.6/4.5/4.1, Claude Sonnet 4.6/4.5, and Claude Haiku 4.5
  models, with a permissive fallback for future `claude-*` models.
- Deprecated or retired Claude IDs return tagged `:deprecated_model` errors
  with `:replacement`, `:expected`, and retirement metadata instead of falling
  through to the family fallback.
- `claude-opus-4-1-20250805` is retired as of August 5, 2026 and resolves to a
  tagged replacement error naming `claude-opus-4-8`; it is no longer an active
  checked-in profile.
- Request builders include Anthropic spec fields such as `:cache_control`,
  `:container`, `:metadata`, `:service_tier`, `:diagnostics`, `:speed`,
  `:user_profile_id`, `:inference_geo`, `:context_management`, `:mcp_servers`,
  `:fallbacks`, `:thinking`, and `:output_config`.
- Claude Opus 5, Claude Sonnet 5, Claude Opus 4.7, and later models follow
  Anthropic's current request restrictions: non-`1.0` `:temperature`, any
  `:top_k`, `:top_p` below `0.99`, and non-adaptive enabled `:thinking` fail
  before the transport call.
- Claude Opus 5 uses adaptive thinking by default and supports `:low`,
  `:medium`, `:high`, `:xhigh`, and `:max` effort. Explicitly disabled thinking
  is rejected at `:xhigh` and `:max`.
- Claude Fable 5.1 and invite-only Claude Mythos 5.1 have 1M-token context
  windows, 128K output limits, the full effort ladder, and always-on adaptive
  thinking. BeamWeaver rejects disabled thinking and forced `:any` or named
  tool choices before both Messages and count-tokens requests; `:auto` and
  `:none` remain supported.
- Fable 5.1 and Mythos 5.1 do not support final assistant-message prefills.
  Their thinking blocks are bound to the exact conversation prefix and must be
  replayed append-only; earlier Claude models cannot consume them. Applications
  that intentionally edit history can use the
  `thinking-binding-controls-2026-08-01` beta and set
  `prefix_mismatch_behavior` to `"drop_block"`; BeamWeaver infers the beta
  header from this request option. Built-in summarization,
  compact-conversation, and local context-editing middleware automatically
  strip carried reasoning blocks when they rewrite prior history. Applications
  that vary system prompts or tool definitions between calls should use the
  same `drop_block` control because those values also participate in the bound
  prefix.
- Fable 5.1 and Mythos 5.1 use a 512-token prompt-cache minimum and $0.25 per
  million cache-read tokens, alongside current standard, cache-write, and batch
  pricing metadata.
- Opus 5 supports mid-conversation system messages and beta tool-change blocks.
  BeamWeaver infers the tool-change beta header. Server-side fallbacks accept
  either a model list or `:default`, with the matching beta header inferred.
- Anthropic does not expose web fetch or Priority Tier on Opus 5. BeamWeaver
  rejects `BeamWeaver.Anthropic.Tools.web_fetch/1` for that profile before
  transport.
- Claude Sonnet 5 supports thinking levels through adaptive thinking:
  use `thinking: %{type: :adaptive}` with `effort: :high`, `:xhigh`, or `:max`.
  BeamWeaver records the requested effort and Anthropic usage details in trace
  metadata for WeaveScope ingestion.
- Current Opus 4.5, Sonnet 4.5, and Haiku 4.5 profiles carry standard,
  cache-read, five-minute and one-hour cache-write, batch, and retirement-floor
  pricing metadata so exact usage accounting does not have to infer those
  dimensions from a family default.

## Usage

```elixir
model =
  BeamWeaver.Anthropic.chat_model(
    model: "claude-opus-5",
    effort: :xhigh,
    max_tokens: 64_000,
    api_key: "sk-ant-test"
  )

BeamWeaver.Core.ChatModel.invoke(model, [
  BeamWeaver.Core.Message.user("Write a short haiku about the BEAM.")
])
```

Tools are plain request values:

```elixir
tools = [
  BeamWeaver.Anthropic.Tools.web_search(),
  BeamWeaver.Anthropic.Tools.code_execution(),
  BeamWeaver.Anthropic.Tools.function(my_tool, strict: true)
]

BeamWeaver.Core.ChatModel.invoke(model, messages, tools: tools, tool_choice: :auto)
```

Opus 5 can ask Anthropic to retry classifier refusals on the provider's current
recommended fallback:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, messages, fallbacks: :default)
```

Use `BeamWeaver.Anthropic.Tools.web_fetch/1` only with a model whose Anthropic
feature matrix includes web fetch; Opus 5 does not.

When forwarding tool history from another provider into Anthropic, keep the
native `Message.tool/2` or assistant `tool_calls` history. The Anthropic request
builder normalizes IDs only for the outgoing wire payload, so later BeamWeaver
middleware and tracing still see the original native IDs.

Token counting uses Anthropic's count-tokens endpoint:

```elixir
BeamWeaver.Anthropic.ChatModel.count_tokens(model, [
  BeamWeaver.Core.Message.user("Count this.")
])
```

## Unsupported Anthropic Surfaces

- Bedrock/Vertex Anthropic routing. The direct Anthropic provider is implemented
  first.
- Provider-specific files API helpers beyond message/document block support.
- Managed Agents beta resources from Anthropic's OpenAPI spec, such as
  sessions, environments, skills, memories, vaults, and user profiles, are not
  exposed as first-class BeamWeaver modules yet; supported request fields can be
  passed where the Messages API accepts them.
- Exact Python class identity and serialization compatibility. BeamWeaver keeps
  native Elixir modules and tagged errors.
