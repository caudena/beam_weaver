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
  stream envelopes, and reconstructed final assistant messages.
- The token counting endpoint is exposed through `ChatModel.count_tokens/3`.
- Checked-in model profiles cover Claude Fable 5, Claude Mythos 5, current
  Claude Opus 4.8/4.7/4.6/4.5/4.1, Claude Sonnet 4.6/4.5,
  and Claude Haiku 4.5 models, with a permissive fallback for future
  `claude-*` models.
- Deprecated or retired Claude IDs return tagged `:deprecated_model` errors
  with `:replacement`, `:expected`, and retirement metadata instead of falling
  through to the family fallback.
- Request builders include Anthropic spec fields such as `:cache_control`,
  `:container`, `:metadata`, `:service_tier`, `:diagnostics`, `:speed`,
  `:user_profile_id`, `:inference_geo`, `:context_management`, `:mcp_servers`,
  `:thinking`, and `:output_config`.
- Claude Opus 4.7 and later follow Anthropic's current request restrictions:
  non-`1.0` `:temperature`, any `:top_k`, `:top_p` below `0.99`, and
  non-adaptive enabled `:thinking` fail before the transport call.

## Usage

```elixir
model =
  BeamWeaver.Anthropic.chat_model(
    model: "claude-haiku-4-5-20251001",
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
  BeamWeaver.Anthropic.Tools.web_fetch(),
  BeamWeaver.Anthropic.Tools.function(my_tool, strict: true)
]

BeamWeaver.Core.ChatModel.invoke(model, messages, tools: tools, tool_choice: :auto)
```

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

## Related Guides

- [Models](../models.md)
- [Prompt Caching](../prompt_caching.md#anthropic)
- [Tools](../tools.md#server-side-provider-tools)
- [Messages](../messages.md#standard-content-blocks)
- [Structured Output](../structured_output.md)
