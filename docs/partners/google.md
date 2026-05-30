# BeamWeaver Google

BeamWeaver includes a Gemini Developer API provider under `BeamWeaver.Google`.

## Implemented

- `BeamWeaver.Google.ChatModel` implements `BeamWeaver.Core.ChatModel`.
- Public model identifiers use the `google:` provider prefix, for example
  `google:gemini-3.5-flash`.
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
- `google:gemini-3.5-flash` is checked in with Google's published text-only
  output profile: text, image, video, audio, and PDF input are supported; text
  output, thinking, structured output, function calling, code execution, File
  Search, Google Maps grounding, Search grounding, URL context, caching, batch,
  flex, and priority inference are supported; image generation, audio
  generation, Live API, and computer use are not advertised.
- Responses include normalized usage, reasoning/thinking token metadata,
  safety ratings, grounding metadata, model version, request IDs, and raw
  provider metadata.
- Streaming supports text deltas, typed stream envelopes, and reconstructed
  final assistant messages.
- Checked-in model profiles cover current recommended Gemini chat models.
  Deprecated or near-shutdown models such as Gemini 2.0 Flash, Gemini 2.5
  Flash, Gemini 2.5 Pro, and Gemini 3 Flash Preview are rejected with a
  `:deprecated_model` error and replacement metadata; explicit
  `google:gemini-*` identifiers still use the family fallback for uncataloged
  current model IDs.

## Usage

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("google:gemini-3.5-flash",
    thinking_budget: 512,
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

Token counting uses Gemini's count-tokens endpoint:

```elixir
BeamWeaver.Google.ChatModel.count_tokens(model, [
  BeamWeaver.Core.Message.user("Count this.")
])
```

## Remaining Google Work

- Live-cassette expansion against the Gemini Developer API.
- Vertex AI. That should be a separate explicit adapter/prefix rather than an
  alias of `google:*`.
- Dedicated image, audio, and video generation model modules beyond chat
  response modality options.
- Exact Python class identity and serialization compatibility. BeamWeaver keeps
  native Elixir modules, structs, and tagged errors.

## Related Guides

- [Models](../models.md)
- [Tools](../tools.md#server-side-provider-tools)
- [Messages](../messages.md#standard-content-blocks)
- [Structured Output](../structured_output.md)
- [Tracing](../tracing.md)
