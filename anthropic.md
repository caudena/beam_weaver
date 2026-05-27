# Anthropic Provider Implementation Plan

## Summary

- Add a full `BeamWeaver.Anthropic` partner implementation for chat, streaming,
  tools, legacy LLM completion, token counting, middleware, model profiles,
  docs, and tests.
- Use LangChain Anthropic as a behavior reference, official Anthropic Messages
  API docs as the wire-format source, and BeamWeaver's OpenAI provider as the
  local behavior/style reference.
- Keep Anthropic separated through shared provider helpers so future providers
  can reuse transport, response decoding, SSE parsing, option normalization, and
  message translator contracts.

## Public API And Provider Layer

- Add shared provider infrastructure under `BeamWeaver.Provider`:
  - HTTP client wrapper over `BeamWeaver.Transport` for JSON requests.
  - Shared JSON/error decoder helpers with provider-specific error modules.
  - Shared SSE event parser.
  - Shared option normalization helpers.
  - `MessageTranslator` behavior for provider-specific message adapters.
- Add public Anthropic APIs:
  - `BeamWeaver.Anthropic.chat_model/1`
  - `BeamWeaver.Anthropic.llm/1`
  - `BeamWeaver.Anthropic.tools/0`
  - `BeamWeaver.Models.init_chat_model("anthropic:<model>", opts)`
  - inferred provider support for `claude-*`.
- Do not add Anthropic embeddings; upstream LangChain Anthropic does not provide
  an embedding model.

## Anthropic Implementation

- Implement Anthropic modules under
  `lib/beam_weaver/anthropic` for client, chat model, request builder, message
  translation, response translation, streaming, tools, legacy LLM, output
  parsers, and middleware helpers.
- Client behavior:
  - Default base URL: `https://api.anthropic.com`
  - Messages endpoint: `/v1/messages`
  - Token count endpoint: `/v1/messages/count_tokens`
  - Auth/env: `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_URL`
  - Headers: `x-api-key`, `anthropic-version`, optional `anthropic-beta`, and
    caller-supplied headers.
- Chat request behavior:
  - Support `model`, `max_tokens`, `temperature`, `top_k`, `top_p`,
    `stop_sequences`, `system`, `tools`, `tool_choice`, `thinking`,
    `output_config`, `effort`, `mcp_servers`, `context_management`,
    `reuse_last_container`, `inference_geo`, `stream_usage`, and `model_kwargs`.
  - Lift system messages to top-level `system`; merge adjacent system/user tool
    turns; preserve tool results, server tool calls/results, citations, thinking
    blocks, redacted thinking, media/document blocks, and unknown blocks where
    possible.
  - Convert structured output requests to Anthropic `output_config.format`.
- Tool behavior:
  - Render custom tools as Anthropic `name`, `description`, and `input_schema`.
  - Support Anthropic built-ins and pass-through fields for text editor,
    computer, bash, web search/fetch, code execution, MCP toolsets, memory, and
    tool search.
  - Implement Anthropic tool-choice semantics for `"auto"`, `"any"`, named
    forced tools, and `disable_parallel_tool_use`.
- Response and streaming behavior:
  - Convert Anthropic responses to `BeamWeaver.Core.Message` with correct
    `content`, `tool_calls`, `usage_metadata`, and `response_metadata`.
  - Include cache read/cache creation token metadata and container/context
    metadata.
  - Stream text, citations, thinking/signature, tool-call JSON deltas, compaction
    deltas, usage, stop reasons, and final reconstructed assistant messages.
  - Expose typed stream events compatible with
    `BeamWeaver.Core.ChatModel.stream_events/3`.
- Model/profile behavior:
  - Add checked-in Anthropic model profiles to
    `BeamWeaver.Models.ProfileRegistry`.
  - Use `claude-haiku-4-5-20251001` as the namespace default model and `4096` as
    the fallback max token limit when profile metadata is unavailable.
  - Add family fallback handling for unknown `claude-*` models.

## Tests

- Remove Anthropic from any provider exclusion lists that still treat it as
  unsupported.
- Add deterministic tests for:
  - Constructor/env/header defaults.
  - Request body generation.
  - Message and content-block translation.
  - Tool rendering/tool choice.
  - Response usage/metadata.
  - Streaming lifecycle and typed events.
  - Token counting.
  - Error mapping and context-overflow detection.
  - Model registry/provider inference.
  - Middleware and output parser behavior.
- Verification commands:
  - `mix format --check-formatted`
  - `mix test`
  - `mix test test/beam_weaver/anthropic test/beam_weaver/provider test/beam_weaver/models`

## Acceptance

- Anthropic chat invoke, batch, async, stream, stream-response, and stream-events
  work through fake/replay transports without live credentials.
- `BeamWeaver.Models.init_chat_model("anthropic:claude-haiku-4-5-20251001")`
  and inferred `claude-*` initialization return Anthropic chat models.
- Every upstream Anthropic public behavior and cassette is either implemented
  with a BeamWeaver test or explicitly documented as idiomatic/no-direct API.
- Existing OpenAI and fake provider tests continue to pass.
