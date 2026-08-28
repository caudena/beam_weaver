# BeamWeaver Google

BeamWeaver includes a Gemini Developer API provider under `BeamWeaver.Google`.

## Implemented

- `BeamWeaver.Google.ChatModel` implements `BeamWeaver.Core.ChatModel`.
- Public model identifiers use the `google:` provider prefix, for example
  `google:gemini-3.7-flash`.
- Bare `gemini-*` identifiers are intentionally rejected so Gemini Developer
  API and future Vertex AI adapters do not share an ambiguous namespace.
- Requests go through `BeamWeaver.Transport`, so fake and replay transports can
  exercise provider behavior without live credentials.
- Namespace constructors load defaults from `config :beam_weaver, :google`;
  put any OS environment reads in your `config/runtime.exs`. Custom routing can
  use configured `:base_url`, explicit `:base_url`, or `:endpoint`.
- BeamWeaver messages become Gemini `contents` plus top-level
  `systemInstruction`.
- Custom tools become Gemini function declarations. Google built-ins such as
  Google Search, Google Maps, URL context, code execution, File Search, MCP
  servers, and model-specific computer use are pass-through provider request
  values.
- Gemini function parameter schemas are provider-sanitized: local `$ref`
  entries are dereferenced, unsupported JSON Schema annotation/object keywords
  such as `$defs`, `title`, `default`, and `additionalProperties` are removed,
  and nested property schemas are cleaned recursively.
- Checked-in profiles include `google:gemini-3.7-flash`,
  `google:gemini-3.6-flash`, `google:gemini-3.5-flash`,
  `google:gemini-3.5-flash-lite`, `google:gemini-3.1-flash-lite`, and
  `google:gemini-3.1-pro-preview`. They accept text, image, video, audio, and PDF
  input and support thinking, structured output, function calling, caching,
  batch, flex, and priority inference.
- Built-in tools are profile-qualified. The 3.7, 3.6, 3.5, and 3.5 Flash-Lite
  profiles include preview computer use. Gemini 3.1 Flash-Lite and 3.1 Pro
  Preview explicitly do not; callers get profile validation rather than a
  provider-side surprise.
- These models use `thinking_level` instead of `thinking_budget`. Gemini 3.7
  Flash supports `low`, `medium`, and `high` and defaults to `medium`; Gemini
  3.6 Flash also defaults to `medium`, while Gemini 3.5 Flash-Lite defaults to
  `minimal`.
  Google deprecates and ignores `temperature`, `top_p`, and `top_k` for these
  releases and does not support `candidate_count`, so their checked-in profiles
  reject those options before transport. They also reject requests whose last
  non-empty content turn has the Gemini `model` role; append a user or tool
  result turn instead of prefilling model output.
- Responses include normalized usage, reasoning/thinking token metadata,
  safety ratings, grounding metadata, model version, request IDs, and raw
  provider metadata.
- Streaming supports text deltas, typed stream envelopes, and reconstructed
  final assistant messages.
- Checked-in model profiles cover current recommended Gemini chat models.
  Stable Gemini 2.5 Pro, Flash, and Flash-Lite identifiers remain accepted
  through the explicit `google:gemini-*` family fallback. Retired preview
  variants, Gemini 2.0 Flash, and Gemini 3 Flash Preview return a
  `:deprecated_model` error with replacement and shutdown metadata.
- Gemini 3.5 Flash Cyber is not registered as a callable chat model. Google
  limits it to governments and trusted partners through CodeMender rather than
  exposing it through the Gemini Developer API, so its slug returns an
  `:unsupported_model` error before family fallback. See
  [Google's release announcement](https://blog.google/innovation-and-ai/models-and-research/gemini-models/gemini-3-6-flash-3-5-flash-lite-3-5-flash-cyber/)
  for the stated rollout boundary.

## Current Flash Profiles

Prices are USD per one million tokens for the Gemini Developer API. Cached
input is the context-caching token price. Gemini 3.7 Flash and 3.6 Flash use
Google's current introductory pricing. The 3.7 Flash entry uses that pricing
through December 31, 2026; its standard rates double on January 1, 2027. Its
introductory cache storage price is $0.50 per one million tokens per hour.

| BeamWeaver ID | Input / output limit | Standard input / cached input / output | Batch and flex input / cached input / output | Priority input / cached input / output |
| --- | --- | --- | --- | --- |
| `google:gemini-3.7-flash` | 1,048,576 / 65,536 | $0.75 / $0.075 / $3.75 | $0.375 / $0.0375 / $1.875 | $1.35 / $0.135 / $6.75 |
| `google:gemini-3.6-flash` | 1,048,576 / 65,536 | $0.75 / $0.075 / $3.75 | $0.375 / $0.0375 / $1.875 | $1.35 / $0.135 / $6.75 |
| `google:gemini-3.5-flash` | 1,048,576 / 65,536 | $1.50 / $0.15 / $9.00 | $0.75 / $0.075 / $4.50 | $2.70 / $0.27 / $16.20 |
| `google:gemini-3.5-flash-lite` | 1,048,576 / 65,536 | $0.30 / $0.03 / $2.50 | $0.15 / $0.02 / $1.25 | $0.54 / $0.05 / $4.50 |
| `google:gemini-3.1-flash-lite` | 1,048,576 / 65,536 | $0.25 / $0.025 / $1.50 | $0.125 / $0.0125 / $0.75 | $0.45 / $0.045 / $2.70 |

For Gemini 3.1 Flash-Lite, audio input is priced separately at $0.50 standard,
$0.25 batch/flex, and $0.90 priority per million audio tokens. Cached audio
input is $0.05, $0.025, and $0.09 respectively. Standard cache storage is $1.00
per million tokens per hour and priority storage is $1.80. The profile records
a scheduled shutdown on May 7, 2027 with Gemini 3.5 Flash-Lite as its
recommended replacement.

From January 1, 2027, Gemini 3.7 Flash standard input, cached input, and output
rates become $1.50, $0.15, and $7.50 respectively. See the live pricing page
for the corresponding batch, flex, priority, and storage rates.

See Google's [model specifications](https://ai.google.dev/gemini-api/docs/models)
and [Gemini Developer API pricing](https://ai.google.dev/gemini-api/docs/pricing)
for the live provider source of truth.

## Usage

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("google:gemini-3.7-flash",
    thinking_level: :medium,
    include_thoughts: true
  )

BeamWeaver.Core.ChatModel.invoke(model, [
  BeamWeaver.Core.Message.user("Summarize the tradeoffs in one paragraph.")
])
```

Provider tools are request values:

```elixir
tools = [
  BeamWeaver.Google.Tools.google_search(),
  BeamWeaver.Google.Tools.google_maps(),
  BeamWeaver.Google.Tools.code_execution(),
  BeamWeaver.Google.Tools.file_search(["fileSearchStores/my_store"]),
  my_local_tool
]

BeamWeaver.Core.ChatModel.invoke(model, messages, tools: tools, tool_choice: :auto)
```

Structured output maps to Gemini generation config:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, messages,
  response_format: %{
    schema: %{
      type: :object,
      properties: %{answer: %{type: :string}},
      required: [:answer]
    }
  }
)
```

When a structured-output request does not set `:max_output_tokens`,
BeamWeaver uses the model profile's output limit for Gemini. For example,
`google:gemini-3.7-flash` defaults structured-output calls to `65_536`
`maxOutputTokens`, while an explicit `max_output_tokens:` value still wins.

Token counting uses Gemini's count-tokens endpoint:

```elixir
BeamWeaver.Google.ChatModel.count_tokens(model, [
  BeamWeaver.Core.Message.user("Count this.")
])
```

## Unsupported Google Surfaces

- Vertex AI. That should be a separate explicit adapter/prefix rather than an
  alias of `google:*`.
- Dedicated image, audio, and video generation model modules beyond chat
  response modality options.
- Exact Python class identity and serialization compatibility. BeamWeaver keeps
  native Elixir modules, structs, and tagged errors.
