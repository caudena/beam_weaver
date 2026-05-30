# BeamWeaver OpenAI

The first OpenAI slices target non-Azure OpenAI paths used by the pinned
LangChain OpenAI package.

## Implemented

- `BeamWeaver.OpenAI.ChatModel` implements `BeamWeaver.Core.ChatModel`.
- `BeamWeaver.OpenAI.EmbeddingModel` implements
  `BeamWeaver.Core.EmbeddingModel`.
- Requests go through `BeamWeaver.Transport`, so provider tests can run against
  replay cassettes and live calls can use Req/Finch.
- BeamWeaver messages become Responses API `input` items.
- BeamWeaver tools become OpenAI `function` tool declarations.
- `BeamWeaver.OpenAI.ToolCalling` builds Responses API built-in tool
  declarations for web search, file search, code interpreter, image generation,
  MCP, custom tools, and tool search.
- `BeamWeaver.OpenAI.Responses` builds raw multi-turn input items and extracts
  preserved output items from assistant responses.
- Structured output options become `text.format` JSON schema requests.
- Strict structured-output schemas are normalized for OpenAI: object schemas
  are closed, optional properties become nullable required fields, stale
  `required` entries are dropped, and unsupported validation/composition
  keywords are removed before request rendering.
- Responses API request options include reasoning, include, previous response
  IDs, raw input items, tool choice, truncation, text verbosity, context
  management, audio/modalities, metadata, service tier, store, model kwargs, and
  common sampling controls.
- Opt-in `include_response_headers` preserves normalized transport response
  headers on assistant message metadata for sync and Task-backed async chat
  calls.
- Responses API JSON results become assistant messages with text, function tool
  calls, and preserved built-in output blocks.
- Structured output responses are JSON-decoded into message metadata, and caller
  parser/validator failures return an OpenAI error with the assistant response
  attached for debugging.
- LangChain v3 Responses edge blocks are preserved across input and output:
  assistant `function_call` items, grouped assistant text/refusal message blocks,
  invalid function-call argument strings, web/file search outputs, response
  errors, incomplete details, and provider metadata.
- Multi-turn helpers preserve custom tool calls, image generation calls, MCP
  approval requests, encrypted reasoning items, and assistant message output
  items so they can be sent back in the next Responses API turn.
- Assistant output items replayed through normal messages strip BeamWeaver
  internal fields such as `raw_provider_block`, while reasoning blocks keep only
  OpenAI-accepted replay fields.
- Embeddings support document/query calls, dimensions, caller chunk size,
  Task-backed async calls, and opt-in `skip_empty` handling.
- Responses API and chat-completions SSE bodies are parsed into text deltas.
- `BeamWeaver.OpenAI.Streaming.response/1` reconstructs final Responses API
  output items from SSE streams for text, reasoning summaries, function calls,
  and terminal built-in tool output items.
- Streaming image generation requests add `partial_images: 1` when needed, and
  partial image frames are preserved on reconstructed `image_generation_call`
  output items.
- `BeamWeaver.OpenAI.ChatModel.stream_response/3` consumes a streaming Responses
  API response and returns a reconstructed assistant message when callers need
  tool calls or raw output items, while `stream/3` remains the text-chunk API.
- `BeamWeaver.OpenAI.ChatModel.async_invoke/3`, `async_batch/3`,
  `async_stream/3`, `async_stream_response/3`, and `async_stream_events/3` expose
  Task-backed async public APIs. Embeddings expose matching Task-backed async
  invoke and batch helpers.
- `BeamWeaver.OpenAI.Streaming.lifecycle_events/1` and
  `BeamWeaver.OpenAI.ChatModel.stream_events/3` expose message and content-block
  lifecycle events for streamed text, reasoning, tool calls, and built-in output
  blocks.
- OpenAI namespace constructors load defaults from `config :beam_weaver,
  :openai`; put any OS environment reads in your `config/runtime.exs`.
  Explicit options still win. Custom routing uses explicit `:endpoint` options
  on the provider model/client structs.
- Streamed tool-search loops preserve `tool_search_call`,
  `tool_search_output`, streamed `function_call`, and the follow-up
  `function_call_output` turn through raw Responses API input items.
- Agent-style function loops preserve raw reasoning/function-call output items
  and follow-up `function_call_output` input items in both JSON and streaming
  Responses API paths.
- Streamed compaction preserves the server `compaction` output item so later
  turns can send it back unchanged.
- Phase-tagged output text preserves `phase` metadata for commentary and final
  answer blocks, including streamed lifecycle events.
- Audio input blocks are converted to OpenAI `input_audio` request parts, audio
  output parts are preserved as message content blocks and metadata, and audio
  output modality options can be sent through the Responses request body.
- GPT-5-family request controls follow OpenAI constraints: `max_tokens` and
  `max_completion_tokens` map to Responses `max_output_tokens`, and temperature
  is omitted for GPT-5 models unless reasoning effort is `none`.
- Replay-backed provider tests cover the OpenAI cassette shapes that map to
  BeamWeaver's Responses-oriented chat model.

## Replay Usage

```elixir
model =
  BeamWeaver.OpenAI.chat_model(
    api_key: "sk-replay",
    transport: BeamWeaver.Transport.Replay,
    transport_opts: [cassette_path: "priv/openai/cassettes/supervised_openai_agent.yaml"]
  )

BeamWeaver.Core.ChatModel.invoke(model, [
  BeamWeaver.Core.Message.user("agent ping")
])
```

Built-in tool declarations are plain request values:

```elixir
tools = [
  BeamWeaver.OpenAI.ToolCalling.web_search(),
  BeamWeaver.OpenAI.ToolCalling.file_search(["vs_123"]),
  BeamWeaver.OpenAI.ToolCalling.code_interpreter(%{type: :auto})
]
```

Multi-turn output items can be fed back explicitly:

```elixir
{:ok, first} = BeamWeaver.Core.ChatModel.invoke(model, messages, tools: tools)

input_items =
  [BeamWeaver.OpenAI.Responses.message(:user, "original prompt")] ++
    BeamWeaver.OpenAI.Responses.output_items(first) ++
    [BeamWeaver.OpenAI.Responses.custom_tool_call_output("call_123", "27")]

BeamWeaver.Core.ChatModel.invoke(model, [], input_items: input_items, tools: tools)
```

The replay matcher compares method, URL, and canonical JSON body. Tests for
tools, structured output, reasoning, MCP approvals, and tool search intentionally
depend on that matcher so request shape regressions fail before a live provider
call is involved.

Run the supervised replay demo with:

```bash
mix run examples/supervised_openai_agent.exs
```

## Required Remaining OpenAI Work

- Azure OpenAI.
- The remaining `ChatOpenAI`, `OpenAIEmbeddings`, and `OpenAI` option surfaces
  not yet covered by replay-backed tests.
- Remaining async edge cases beyond the Task-backed public APIs, including
  callback/client wrapper behavior and stream chunk timeout behavior.
- Remaining audio API surfaces beyond the current chat audio request/response shape.
- Remaining LangChain v3 protocol edge cases not covered by the current
  Responses message conversion tests.
- LangSmith exporter hardening against live LangSmith API fixtures beyond the
  current compatible trace payload boundary.

## Related Guides

- [Models](../models.md)
- [Tools](../tools.md#server-side-provider-tools)
- [Structured Output](../structured_output.md)
- [Replay](../replay.md)
- [Tracing](../tracing.md)
