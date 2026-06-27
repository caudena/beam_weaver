# Changelog

## 0.1.4 - 2026-06-25

### Added

- Added OpenAI Responses `store: false` replay sanitization for cached
  assistant messages. Replay now drops provider-only item IDs, skips
  non-replayable reasoning and empty image-generation blocks, and preserves
  encrypted reasoning content that can safely round-trip.
- Added OpenAI `apply_patch` built-in tool rendering and replay parsing for
  `apply_patch_call` and `apply_patch_call_output` provider items.
- Added an offline OpenAI `apply_patch` example that shows request rendering and
  replayable assistant patch history without requiring live credentials.
- Added replay-backed provider conformance fixtures for OpenAI replay
  sanitization and xAI reasoning request-shape handling.
- Added WeaveScope exporter queue telemetry coverage for retry, flush,
  rejection, and dead-letter paths.
- Added `tool_call_streaming` to model capability profiles and exposed it through
  profile compilation, compatibility checks, and the profile matrix task.
- Added pre-projection message stream transforms, including a PII stream
  redaction helper that edits typed token/message envelopes before projection.
- Added Agent Protocol client hardening for encoded task paths,
  JSON-string/map body normalization, non-2xx error payloads, and async-subagent
  native trace metadata.
- Added a native sandbox provider registry with validated provider specs,
  builtin local provider construction, lifecycle capability checks, and redacted
  provider metadata.
- Added explicit interpreter adapter contracts and a supervised interpreter
  session boundary for adapter-owned eval, snapshot, restore, timeout, cancel,
  and close behavior without adding a default unsafe interpreter runtime.

### Changed

- Anthropic tool-call IDs are now normalized deterministically at the Anthropic
  provider boundary while preserving BeamWeaver's native message and tool-call
  structs.
- xAI reasoning profiles omit unsupported `stop` request parameters while
  non-reasoning xAI chat-completions models continue to send supported stop
  sequences.
- Deep Agents offload and model-request metadata now use BeamWeaver-native keys
  such as `:offloaded_to` and `:source` instead of Python ecosystem labels.
- WeaveScope trace payload tests now assert native BeamWeaver/WeaveScope fields
  for run envelopes, model generation details, tool payloads, usage, lifecycle
  status, event versions, tags, and metadata.
- OpenAI and xAI stream handling now preserves empty initial chunks,
  incremental tool-call arguments, reconstructed final assistant tool calls, and
  detailed usage metadata.
- Summarization triggers now support explicit AND/OR composition with
  `{:all, triggers}` and `{:any, triggers}`.
- Human-in-the-loop middleware now supports predicate-gated review configs and
  `interrupt_mode: :first` for reviewing only the first matching tool call.
- Sandbox and filesystem command execution results now carry additive native
  metadata such as provider ID, sandbox ID, command ID, snapshot ID, reconnect
  count, timeout, exit status, retryability, and raw provider status when the
  backend supplies it.

### Fixed

- Graph task exits, timeouts, and cancellations now preserve the BEAM root cause
  in normalized graph errors and emit native graph telemetry for failure paths.
- Checkpoint serialization tests now guard that only known BeamWeaver tagged
  structs decode, while foreign constructor-shaped maps remain inert data.
- Transport and trace redaction now cover nested bearer tokens, provider keys,
  URL credentials, query-string secrets, env-style assignments, private key
  blocks, and secret headers without redacting token-count usage fields.
- `list_async_tasks` refreshes active async tasks while leaving terminal task
  records cached, so completed/cancelled/error tasks are not re-polled.
- Sandbox execution, remote-provider fakes, interpreter sessions, and shell
  commands now normalize timeout/crash metadata and emit native telemetry while
  redacting credential-shaped fields before tracing.

## 0.1.3 - 2026-06-23

### Added

- Added a first-class Z.ai provider for `zai:glm-5.2`, including runtime
  config from `ZAI_API_KEY`, optional Z.ai base URL overrides, provider/model
  registry entries, model profile metadata, and provider matrix support.
- Added native Z.ai chat-completions support for non-streaming and streaming
  responses, JSON mode, function tools, streamed tool-call argument merging,
  reasoning deltas, request metadata, raw usage, and estimated cost metadata.

## 0.1.2 - 2026-06-20

### Fixed

Security and transport:

- SSRF: Req no longer auto-follows redirects. Every redirect hop is validated
  against the URL policy, including on streaming paths.
- PII: overlapping detector spans (such as a URL containing an IP) no longer
  crash or garble output. Spans are pruned to stay disjoint.
- IPv4 reserved-range checks no longer over-block public `/16` ranges.
- IPv6 `fe80::/10` is treated as reserved, so it stays blocked when
  `allow_metadata?` is on.
- Per-call request options (including `:timeout`) override client transport
  defaults instead of being shadowed.

Providers:

- Anthropic: beta flags go in the `anthropic-beta` header, not the body. This
  covers invoke, stream, stream_events, and count_tokens.
- Anthropic: final streaming usage is a proper usage map merged into metadata.
- Anthropic: a non-list `:tools` option (such as `nil`) no longer raises; tools
  are omitted.
- Google: streaming tolerates chunks with no candidates, content, or parts.
- Google: `countTokens` sends exactly one of `contents` or
  `generateContentRequest`.
- OpenAI: a bare-string `:image_url` block is handled instead of crashing.
- OpenAI: model inference is limited to `o1`/`o3`/`o4`/`chatgpt` prefixes, so
  other models are not misrouted.
- OpenAI: parsing a chunk with no tool calls returns `[]`, not an error.
- xAI: `ChatCompletionsModel.new/1` no longer crashes on `streaming: true`.
- Moonshot: the tool-name regex accepts short and digit/hyphen-leading names.
- Provider runtime: stream-metadata returns `%{}` instead of crashing when an
  adapter has no metadata function.
- Cached models keep usage cost on a cache miss, for both stream and
  stream_events.

Agents and middleware:

- `interrupt_before`/`interrupt_after: :all` is preserved instead of becoming
  `[:all]`, which had disabled all human-in-the-loop interrupts.
- Structured final-response extraction handles string-keyed state instead of
  crashing.
- `list_async_tasks` refreshes live status before filtering, not stale status.
- A configured subagent-output response that is not a map or function is honored,
  not dropped.
- The tool emulator falls back to `"unknown_tool"` when a tool call has no name.

Graph:

- Validation-node task exits become error messages instead of crashing the node.
- Pending checkpoint-map merging tolerates a missing `configurable` key.
- Delta channels keep `nil`/`false` overwrite values instead of resetting to the
  initial value.
- `input_channels` hides private channels (such as `__node_outputs__`) when there
  is no `input_schema`.
- An empty-list edge condition is treated as membership, not a match-anything map.
- `add_messages` honors the last `remove_all` marker, not the first.
- OpenAI message formatting tags tool calls as `"tool_call"`, not `"tool_calls"`.
- `ServerInfo.User` Access no longer leaks struct-field keys into user metadata.

Memory, retrieval, and indexing:

- Ecto memory applies `default_ttl` on write. Refresh-on-read updates only
  `expires_at`, not `updated_at`.
- ETS chat history no longer drops messages under concurrent `add_messages`;
  writes are atomic.
- Indexing without a record manager deduplicates documents that share an id.
- ETS memory namespace listing ignores unknown match-condition types instead of
  crashing.
- Memory metadata filters match a plain-map value by equality instead of always
  failing.
- Vector-store SQL filters render `$and`/`$or`/`$not`.
- The policy retriever honors `:similarity_score` and `score_threshold`.
- The SQL `$like` filter keeps the user pattern verbatim, matching ETS `like`.
- ETS vector store stringifies ids in `delete`/`get_by_ids`, so non-string ids
  match.
- File-search snippets slice with correct offsets, fixing garbled multibyte text.
- `add_start_index` reports a character index, not a byte offset.

Rate limiting:

- The rate-limited wrapper streams through `ChatModel.stream/3` instead of
  degrading to invoke when the provider module is not loaded.
- Token-bucket `acquire` rejects negative or non-integer timeouts and invalid
  modes up front.
- Retry delays are re-clamped to `max_delay` after jitter, including the
  zero-backoff path.

Serialization and schema:

- Maps with colliding atom/string keys raise instead of silently dropping one.
- The pretty JSON encoder escapes all control characters.
- Structured-output `oneOf` variants get distinct spec names.
- A nullable typeless tool field becomes `anyOf[…, null]`, not null-only.
- Checkpoint config normalization returns `%{}` when `configurable` is `nil`.
- `MapAccess.first` returns a `false`/`nil` value instead of the default.
- Empty-string schema defaults are emitted, not dropped.
- Strict tool-schema rendering keeps user keys with `nil` values.
- Schema fields given as 2-tuples normalize instead of crashing.
- Tracing `custom_fields` skips non-pair list entries instead of crashing.

Core messages and text:

- XML output parsing slices on byte offsets, fixing multibyte corruption.
- Tool-result truncation backs off to a valid UTF-8 boundary.
- Trimming with `:last` keeps the last words, not the first.
- Usage subtraction clamps right-only token counts to zero, including nested maps.
- The `drop_oldest` mux drops the newest item instead of erroring when the buffer
  is full.
- Prompt partials and the simple template renderer no longer mishandle supplied
  or brace values.
- Partial JSON repair is no longer cubic on long input.
- Fixed assorted dead and edge-case clauses: agent decision normalization,
  transient-error and MFA retry predicates, and the HTML header splitter.

Sandbox and shell:

- Docker `edit/5` starts the container once and threads it through
  read/write/execute. Edits previously hit throwaway containers and leaked
  containers.
- Docker execute/read truncation respects UTF-8 codepoint boundaries.
- The Docker sandbox prints the entry type before the path, so `ls`/`glob` handle
  paths containing `|`.
- File-formatting long-line chunking splits on character boundaries, not raw
  bytes.
- A host shell command no longer crashes when the policy timeout is `nil`.
- Shell host-executor and session temp files are cleaned up even on timeout or
  kill.

### Changed

- Default operation timeout raised from 5 seconds to 5 minutes for runnable
  `batch`/`map`/`parallel`/fallback and the agent `GenServer.call`. An explicit
  `:timeout` still overrides it.

### Internal

- Removed dead clauses and other compiler-warning sources. `mix compile` and
  `mix test` now run clean.

## 0.1.1 - 2026-06-20

### Added

- Added Moonshot/Kimi profiles for `kimi-k2.7-code`,
  `kimi-k2.7-code-highspeed`, `kimi-k2.6`, and `kimi-k2.5`.
- Added request validation for Kimi thinking, fixed sampling, and tool-choice
  constraints.
- Added an Apache License 2.0 `LICENSE` file.

### Changed

- Updated Moonshot/Kimi docs and install snippets for the `0.1.1` release.
