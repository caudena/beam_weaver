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
  MCP, custom tools, tool search, and OpenAI's `apply_patch` tool.
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
- `store: false` replay sanitization is applied before the request body is sent:
  provider-only output item IDs are dropped, encrypted reasoning is preserved,
  non-replayable reasoning is skipped, and empty image-generation placeholders
  are not sent back to OpenAI.
- Responses API output parsing preserves `apply_patch_call` and
  `apply_patch_call_output` items as provider-scoped content blocks so cached or
  streamed turns can be replayed without losing patch metadata.
- Embeddings support document/query calls, dimensions, caller chunk size,
  Task-backed async calls, and opt-in `skip_empty` handling.
- Responses API and chat-completions SSE bodies are parsed into text deltas.
- OpenAI GPT model profiles expose `tool_call_streaming: true` when the checked-in
  profile supports incremental streamed tool-call arguments.
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
- Chat Completions streams preserve empty initial role-only chunks, incremental
  tool argument deltas, final assistant tool calls, finish reasons, and detailed
  usage metadata.
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
- GPT-5.6 requests support `prompt_cache_options`, explicit cache breakpoints on
  content parts, Responses file `detail`, normalized cache-write usage, and a
  model-level `safety_identifier`.
- GPT-5.6 Chat Completions function tools are rejected before transport unless
  the effective reasoning effort is `none`; reasoning plus tools uses Responses.
- Replay-backed provider tests cover the OpenAI cassette shapes that map to
  BeamWeaver's Responses-oriented chat model.

## GPT-5.6 Profiles

BeamWeaver includes `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna` as
first-class OpenAI profiles. The official `gpt-5.6` alias resolves to Sol. All
three profiles expose a 1.05M-token context window, 128K maximum output, text
and image input, Responses and Chat Completions, function calling, structured
output, streaming, and the current OpenAI built-in tool catalog.

Standard prices per million tokens are:

| Model | Input | Cached input | Cache write | Output |
| --- | ---: | ---: | ---: | ---: |
| `gpt-5.6-sol` | $5.00 | $0.50 | $6.25 | $30.00 |
| `gpt-5.6-terra` | $2.50 | $0.25 | $3.125 | $15.00 |
| `gpt-5.6-luna` | $1.00 | $0.10 | $1.25 | $6.00 |

Requests above 272K input tokens use OpenAI's higher-context rates: 2x input
and 1.5x output for the full request. GPT-5.6 cache writes cost 1.25x uncached
input, cache reads receive the 90% discount, and the current cache TTL is 30
minutes. Eligible regional-processing endpoints add OpenAI's 10% uplift.

The existing `reasoning` request option carries GPT-5.6 controls without a
separate model type:

```elixir
BeamWeaver.Models.init_chat_model!("openai:gpt-5.6-sol",
  reasoning: %{effort: :max, mode: :pro, context: :all_turns}
)
```

Persisted reasoning context returned by Responses is preserved as
`message.response_metadata.reasoning_context`. Explicit GPT-5.6 prompt caching is
available on both OpenAI APIs:

```elixir
BeamWeaver.Models.init_chat_model!("openai:gpt-5.6",
  prompt_cache_options: %{mode: :explicit, ttl: "30m"},
  safety_identifier: "user_<stable_privacy_preserving_hash>"
)
```

Mark the desired text, image, or file content block with
`metadata.prompt_cache_breakpoint`. Cache reads and writes are normalized to
`usage_metadata.input_token_details.cache_read` and `cache_write`.

On Chat Completions, GPT-5.6 function tools require
`reasoning_effort: :none`. BeamWeaver returns `:invalid_model_option` before
transport when this combination is invalid and points callers to Responses.

OpenAI's programmatic tool calling and hosted multi-agent beta are recorded as
provider capabilities in profile metadata. BeamWeaver does not yet provide
dedicated request/response helpers for those two hosted orchestration surfaces.

## Replay Usage

```elixir
model =
  BeamWeaver.OpenAI.chat_model(
    api_key: "sk-replay",
    transport: BeamWeaver.Transport.Replay,
    transport_opts: [cassette_path: "path/to/my_agent_response.yaml"]
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
  BeamWeaver.OpenAI.ToolCalling.code_interpreter(%{type: :auto}),
  BeamWeaver.OpenAI.ToolCalling.apply_patch()
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

For cached multi-turn Responses replay, pass `store: false` through model
options or `extra_body`. BeamWeaver will keep the replayable parts of assistant
history while removing provider-generated item IDs that OpenAI rejects when
storage is disabled:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, messages, extra_body: %{store: false})
```

Replay coverage for this request shape includes encrypted reasoning
preservation and provider-only ID removal.

Run the supervised demo with:

```bash
mix run examples/supervised_agent.exs
```

Inspect the OpenAI `apply_patch` built-in tool request shape without live
credentials:

```bash
mix run examples/openai_apply_patch_tool.exs
```

## Unsupported OpenAI Surfaces

- Azure OpenAI.
- `ChatOpenAI`, `OpenAIEmbeddings`, and `OpenAI` Python compatibility surfaces
  that do not map to the current BeamWeaver chat, embeddings, and Responses
  APIs.
- Callback/client wrapper behavior outside the Task-backed async public APIs.
- Audio API surfaces beyond the current chat audio request/response shape.
- GPT-5.6 programmatic tool calling and OpenAI-hosted multi-agent orchestration.
- LangChain v3 protocol edge cases outside the current Responses message
  conversion layer.
- WeaveScope exporter behavior beyond the native BeamWeaver trace payload
  boundary.

## Related Guides

- [Models](../models.md)
- [Prompt Caching](../prompt_caching.md#openai-responses)
- [Tools](../tools.md#server-side-provider-tools)
- [Structured Output](../structured_output.md)
- [Replay](../replay.md)
- [Tracing](../tracing.md)
