# Changelog

## 0.1.2 - 2026-06-20

### Fixed

Security and safety guarantees:

- Transport: stopped Req from following redirects internally and now validate
  every redirect hop — including on the streaming paths — against the URL policy,
  so the SSRF boundary actually applies to redirects instead of being bypassed.
- Agents: preserved the `interrupt_before`/`interrupt_after: :all` sentinel
  instead of turning it into `[:all]`, which had silently disabled all
  human-in-the-loop interrupts.
- PII middleware: overlapping detector spans (for example a URL containing an IP
  address) no longer crash with an `ArgumentError` or leak/garble redacted text;
  spans are pruned to stay disjoint before splicing.

Provider request/response correctness:

- Anthropic: inferred beta flags are sent via the `anthropic-beta` header instead
  of the request body (covers invoke, stream, stream_events, and count_tokens);
  the final streaming `message_delta` reports usage as a proper usage map merged
  into chunk metadata rather than a discarded message struct.
- Google: streaming tolerates chunks without `candidates`/`content`/`parts`
  (usage- or finish-only chunks); `countTokens` sends exactly one of `contents`
  or `generateContentRequest` (they are mutually exclusive).
- xAI: `ChatCompletionsModel.new/1` no longer crashes with a `KeyError` when given
  `streaming: true`.
- OpenAI: an `:image_url` content block whose `image_url` is a bare string is
  handled instead of crashing on map access.
- Moonshot: the function-tool name regex accepts short and digit/hyphen-leading
  names.

Correctness, crashes, and data integrity:

- Output parser: XML slicing uses byte offsets consistently, fixing corruption of
  multibyte text and attribute values.
- Sandboxes: Docker `edit/5` starts the container once and threads it through
  read/write/execute — the edit previously landed in throwaway containers, never
  modified the real file, and leaked containers; execute/read output truncation
  now respects UTF-8 codepoint boundaries.
- Shell tools: a host command no longer crashes when the policy timeout is `nil`.
- Graph execution: validation-node tasks that exit are turned into error
  messages instead of crashing the node; pending checkpoint-map merging no longer
  crashes when the config lacks a `configurable` key.
- Memory (Ecto): the store `default_ttl` is applied on write so configured TTLs
  expire; refresh-on-read updates `expires_at` only and no longer bumps
  `updated_at`.
- Serialization: maps with colliding atom/string keys raise instead of silently
  dropping an entry; the pretty JSON encoder escapes all control characters so it
  always emits valid JSON.
- Retrieval: vector-store SQL filters render `$and`/`$or`/`$not` logical
  operators; the policy-based retriever honors `:similarity_score` and
  `score_threshold`.
- Other: structured-output `oneOf` variants get distinct spec names; cached models
  no longer zero usage cost on a cache miss; a nullable typeless tool field
  becomes `anyOf[…, null]` instead of a null-only schema; prompt partials and the
  simple template renderer no longer mis-handle supplied/brace values; partial
  JSON repair is no longer cubic on long input; and assorted dead or edge-case
  clauses were fixed (agent decision normalization, transient-error predicates,
  MFA retry predicates, the HTML header splitter, and more).

### Changed

- Raised the default operation timeout for runnable `batch`/`map`/`parallel`/
  fallback and the agent `GenServer.call` from 5 seconds to 5 minutes so real
  model calls are not aborted prematurely; an explicit `:timeout` option still
  overrides it.

### Internal

- Removed dead and redundant clauses and other sources of Elixir 1.19 compiler
  warnings; `mix compile` and `mix test` now run free of warnings and stray error
  logs.

## 0.1.1 - 2026-06-20

### Added

- Added Moonshot/Kimi profiles for `kimi-k2.7-code`,
  `kimi-k2.7-code-highspeed`, `kimi-k2.6`, and `kimi-k2.5`.
- Added request validation for Kimi thinking, fixed sampling, and tool-choice
  constraints.
- Added an Apache License 2.0 `LICENSE` file.

### Changed

- Updated Moonshot/Kimi docs and install snippets for the `0.1.1` release.

