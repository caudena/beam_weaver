# BeamWeaver Replay

Replay transport lets provider tests run against recorded request/response pairs.
It is the default way to prove request shape without using live credentials.

## Transport

Configure a model with `BeamWeaver.Transport.Replay`:

```elixir
model =
  BeamWeaver.OpenAI.chat_model(
    api_key: "sk-replay",
    transport: BeamWeaver.Transport.Replay,
    transport_opts: [
      cassette_path: "path/to/my_agent_response.yaml"
    ]
  )
```

The transport loads plain YAML or gzipped YAML cassettes.
Replace the cassette path with a cassette recorded for the provider request
shape you are testing.

## Matching

Replay matching compares:

- HTTP method
- URL, unless the cassette URL is `**REDACTED**`
- canonical JSON request body when the body is JSON
- raw request body as a fallback

Canonical JSON matching is intentional. Tests should fail when a provider drops
important request fields such as tools, structured output, `stream`, reasoning,
context management, raw Responses API input items, or follow-up tool outputs.

For OpenAI Responses `store: false` replay, BeamWeaver sanitizes assistant
history before matching or sending the request: provider-only IDs are removed,
encrypted reasoning is preserved, non-replayable reasoning is skipped, and empty
image-generation placeholders are dropped. This keeps replay tests aligned with
the actual provider wire contract instead of cached local message internals.

## Durable Provider-Native Replay

Transport cassettes reproduce HTTP exchanges in tests. Durable application
runtimes need a different artifact: the bounded assistant content that must be
sent back to the same provider on a later turn. Use
`BeamWeaver.Provider.Response.normalize_execution_result/3` to obtain the
normalized message, its closed outcome classification, and that replay
projection together:

```elixir
{:ok, execution} =
  BeamWeaver.Provider.Response.normalize_execution_result(model, assistant_message,
    replay_binding: %{
      provider: :anthropic,
      model: "claude-opus-5",
      profile: "claude-opus-5"
    }
  )

persist(execution.message, execution.outcome, execution.replay)
```

`BeamWeaver.Provider.Replay` retains only request-critical assistant blocks and
tool-call correlation fields. It deliberately excludes raw HTTP bodies, usage,
traces, tool-result bodies, and arbitrary response metadata. Anthropic fallback
boundary blocks retain their raw provider payload inside the bounded projection
so a later exact replay does not silently change provider semantics.

Before materializing persisted content, restore it against the exact expected
binding:

```elixir
{:ok, assistant_message} =
  BeamWeaver.Provider.Replay.restore(persisted_projection, expected_binding)
```

A provider, model, or profile mismatch returns
`:provider_replay_binding_mismatch` before any content is reconstructed.
`binding_matches?/2` is available when a recovery scan needs to discard foreign
rows before applying aggregate content limits.

`BeamWeaver.Provider.Outcome` classifies each normalized provider turn along
three independent axes: remote status, turn disposition, and result
completeness. Provider status is evidence, not control flow. Applications
should branch on the closed outcome—for example `:awaiting_client_tools`,
`:awaiting_user_input`, `:provider_pause`, `:context_limit`, or
`:no_usable_output`—rather than inferring completion from the presence of text.

## Cassette Shape

BeamWeaver reads Python VCR-style cassettes with parallel `requests` and
`responses` lists:

```yaml
requests:
- body: !!binary |
    eyJpbnB1dCI6W3siY29udGVudCI6ImFnZW50IHBpbmciLCJyb2xlIjoidXNlciIsInR5cGUiOiJtZXNzYWdlIn1dLCJtb2RlbCI6ImdwdC00by1taW5pIiwic3RyZWFtIjpmYWxzZX0=
  headers:
    authorization:
    - '**REDACTED**'
  method: POST
  uri: https://api.openai.com/v1/responses
responses:
- body:
    string: !!binary |
      eyJvdXRwdXQiOlt7ImNvbnRlbnQiOlt7InRleHQiOiJhZ2VudCBwb25nIiwidHlwZSI6Im91dHB1dF90ZXh0In1dLCJ0eXBlIjoibWVzc2FnZSJ9XX0=
  headers:
    content-type:
    - application/json
  status:
    code: 200
    message: OK
```

Response bodies can also be Server-Sent Events. Set the cassette response content
type to `text/event-stream` for streaming tests.

## Redaction

Replay errors redact request URLs, bodies, and secrets before reporting mismatch
details. Cassettes should still store authorization headers as `**REDACTED**`.

The redactor protects common secret shapes, including authorization headers,
bearer tokens, OpenAI-style secret keys, API key fields, and nested password or
token fields.

## Good Replay Tests

Use replay tests for behavior that catches real regressions:

- request body shape for provider options
- tool declaration shape
- multi-turn Responses API raw output item preservation
- stream reconstruction from SSE events
- error and mismatch behavior
- provider-specific request-shape exceptions, such as OpenAI `store: false`
  replay sanitization or xAI reasoning models omitting unsupported `stop`
  parameters

Avoid tests that only assert a variable equals the literal value just created in
the same test. The useful signal is whether a caller-visible behavior or provider
contract would break.

For application tests, keep request-shape examples as local JSON or YAML
fixtures when credentials are not required. Use live provider calls only for the
small set of checks where provider availability, account configuration, or
current model behavior is the thing being tested.
