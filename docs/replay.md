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
      cassette_path: "priv/openai/cassettes/supervised_openai_agent.yaml"
    ]
  )
```

The transport loads plain YAML or gzipped YAML cassettes.

## Matching

Replay matching compares:

- HTTP method
- URL, unless the cassette URL is `**REDACTED**`
- canonical JSON request body when the body is JSON
- raw request body as a fallback

Canonical JSON matching is intentional. Tests should fail when a provider drops
important request fields such as tools, structured output, `stream`, reasoning,
context management, raw Responses API input items, or follow-up tool outputs.

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

Avoid tests that only assert a variable equals the literal value just created in
the same test. The useful signal is whether a caller-visible behavior or provider
contract would break.

## Related Guides

- [OpenAI](partners/openai.md#replay-usage)
- [Tracing](tracing.md)
