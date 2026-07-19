# Partners

BeamWeaver partner adapters are native Elixir implementations of provider wire
formats. They share the core `BeamWeaver.Core.ChatModel` interface, but each
adapter owns its own message translation, tool rendering, streaming lifecycle,
model profiles, request validation, and replay/fake transport coverage.

Use this page as the support matrix. The first matrix covers provider API
surface. The second matrix covers composed agent capabilities: which model
strings are practical choices when the agent needs planning, tools,
filesystem-backed work, subagents, structured output, human review, and event
streaming.

## Capability Matrix

| Partner | Primary modules | Chat | Chat Completions | Responses API | Embeddings | Tools | Structured output | Streaming | Token counting |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [OpenAI](partners/openai.md) | `BeamWeaver.OpenAI.*` | Yes | Yes | Yes | Yes | Function tools and Responses built-ins | JSON schema via Responses or Chat Completions | Text deltas, lifecycle events, reconstructed responses | Tokenizer/profile based |
| [Anthropic](partners/anthropic.md) | `BeamWeaver.Anthropic.*` | Yes | No | No | No | Custom tools and Anthropic server tools | Tool/schema strategy through model calls | Text deltas, typed events, reconstructed messages | Anthropic count-tokens endpoint |
| [Google](partners/google.md) | `BeamWeaver.Google.*` | Yes | No | No | No | Function declarations and Gemini built-ins | Gemini generation config schema | Text deltas, typed events, reconstructed messages | Gemini count-tokens endpoint |
| [Moonshot/Kimi](partners/moonshot.md) | `BeamWeaver.Moonshot.*` | Yes | Yes | No | No | OpenAI-compatible functions, K3 required/dynamic tools, and legacy Kimi `$web_search` | JSON object/schema request options | Text/reasoning/tool-call deltas, choice- or response-level usage, typed events, reconstructed messages | Moonshot estimate-token endpoint |
| [xAI](partners/xai.md) | `BeamWeaver.XAI.*` | Yes | Yes | Yes | Yes | OpenAI-compatible function tools and xAI built-ins | JSON schema request options | Text deltas, typed events, reconstructed messages | Tokenizer/profile or approximate fallback |
| [Z.ai](partners/zai.md) | `BeamWeaver.ZAI.*` | Yes | Yes | No | No | OpenAI-compatible function tools | JSON object mode plus schema instructions and local validation | Text/reasoning/tool-call deltas, usage chunks, reconstructed messages | Approximate fallback |

## Composed Agent Model Matrix

Deep-agent behavior is composition in BeamWeaver: `TodoList` planning,
filesystem tools, skills, memory files, subagents, interrupts, context editing,
and graph checkpoints are normal agent runtime capabilities. The model adapter
determines whether a composed agent can reliably expose tools, parse structured
output, stream useful events, and count enough tokens for context management.

| Model family | Recommended BeamWeaver strings | Composed agent fit | Tool loop | Structured output | Streaming and observability | Token budget support | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| OpenAI GPT | `openai:gpt-5.6-sol`, `openai:gpt-5.6-terra`, `openai:gpt-5.6-luna`, `openai:gpt-5.4-mini`, explicit `BeamWeaver.OpenAI.*` structs | Strong default | Custom function tools, Responses built-ins, raw Responses tool-result turns | Provider-native Responses or Chat Completions schema; tool strategy fallback at agent layer | Text, reasoning, tool-call lifecycle, reconstructed streamed responses | Tokenizer/profile based with approximate fallback | GPT-5.6 adds 1.05M context, `max` effort, pro mode, and persisted reasoning; hosted multi-agent/programmatic tool calling are not yet wrapped. |
| Anthropic Claude | `anthropic:claude-sonnet-5`, `anthropic:claude-fable-5`, `anthropic:claude-mythos-5`, `anthropic:claude-sonnet-4-6`, `anthropic:claude-opus-*`, `anthropic:claude-haiku-*` | Strong default | Custom tools plus Anthropic server tools through provider helpers | Anthropic output config plus BeamWeaver parsing/validation | Text, typed Anthropic stream envelopes, reconstructed messages | Anthropic count-tokens endpoint | Sonnet 5 uses adaptive thinking with `output_config.effort`; prompt caching and server tools are provider-specific. |
| Google Gemini | `google:gemini-3.5-flash`, other explicit `google:gemini-*` profiles | Supported | Function declarations and Gemini built-ins | Gemini generation config schema | Text, typed Gemini events, reconstructed messages | Gemini count-tokens endpoint | Gemini identifiers must use the `google:` prefix; use workload tests for long tool chains. |
| Moonshot/Kimi | `moonshot:kimi-k3`, `moonshot:kimi-k2.7-code`, `moonshot:kimi-k2.7-code-highspeed`, `moonshot:kimi-k2.6`, `moonshot:kimi-k2.5` | Supported with Kimi constraints | OpenAI-compatible functions; K3 adds required choice and dynamic loading; legacy `$web_search` only where thinking can be disabled | JSON object/schema request options | Text, reasoning, tool-call chunks, usage chunks, reconstructed messages | Moonshot estimate-token endpoint | K3 has 1,048,576-token context/output limits, always reasons with `reasoning_effort: "max"`, and rejects K2 `thinking`; web search is currently being updated by Kimi. |
| xAI Grok | `xai:grok-4.5`, `xai:grok-4.3`, `xai:grok-4.20-0309-reasoning`, explicit `BeamWeaver.XAI.*` structs | Supported | OpenAI-compatible functions and xAI built-ins | JSON schema request options | Text, reasoning/citation metadata, typed events, reconstructed messages | Tokenizer/profile or approximate fallback | Useful for coding, agentic work, and Grok-specific reasoning/citation behavior; provider metadata is normalized. |
| Z.ai GLM | `zai:glm-5.2`, explicit `BeamWeaver.ZAI.ChatModel` structs | Supported | OpenAI-compatible functions with `tool_stream` for streamed arguments | JSON object mode plus BeamWeaver schema instructions and local validation | Text, reasoning, tool-call chunks, usage chunks, reconstructed messages | Approximate fallback | GLM identifiers must use `zai:`; only `glm-5.2` is enabled. Usage includes cached-input and reasoning-token details for cost metadata. |
| Fake chat | `fake:chat` | Test only | Fixture tool calls | Fixture structured responses | Fixture text/events | Fake or approximate | Use for deterministic composed-agent middleware, checkpoint, HITL, and subagent tests. |

This matrix is not a benchmark table. BeamWeaver verifies the runtime surfaces
locally, but it does not publish cross-model Deep Agents eval scores. Validate
model quality against your own tool set, prompts, and latency/cost constraints.

## Common Contract

All first-class partner chat models:

- implement `BeamWeaver.Core.ChatModel`
- accept `BeamWeaver.Core.Message` input
- return `BeamWeaver.Core.Message` output with normalized metadata where the
  provider exposes it
- route HTTP through `BeamWeaver.Transport`
- support fake or replay transports for tests without live credentials
- expose namespace constructors such as `BeamWeaver.OpenAI.chat_model/1`
- participate in `BeamWeaver.Models.init_chat_model/2` provider-prefix routing

## Related Guides

- [Models](models.md)
- [Messages](messages.md)
- [Tools](tools.md)
- [Structured Output](structured_output.md)
- [Replay](replay.md)
- [Tracing](tracing.md)
