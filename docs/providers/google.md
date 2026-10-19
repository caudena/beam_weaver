# Google Gemini

BeamWeaver uses the Gemini Developer API for chat, thinking, supported hosted
tools, media input, token counting and cached-content references. Vertex AI
routing and media-generation models are separate APIs outside this adapter.

## Setup and first request

```elixir
import Config
config :beam_weaver, :google, api_key: System.fetch_env!("GOOGLE_API_KEY")
```

Save configuration in your application runtime file, then make a real request:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}
{:ok, model} = BeamWeaver.Models.init_chat_model("google:gemini-3.5-flash", max_output_tokens: 1_024, timeout: 60_000)
{:ok, reply} = ChatModel.invoke(model, "Explain parcel tracking in one sentence.")
true = byte_size(Message.text(reply)) > 0
true = reply.usage_metadata.total_tokens > 0
```

Use the same identifier in an agent declaration. Gemini IDs require `google:`.
Keep complete messages when continuing function calls; native parts can carry
provider state beyond display text.

## Gemini 4 Argon

Use `google:gemini-4-argon` with `thinking_level: :low`, `:medium` (the provider
default), or `:high`. Its 1,048,576-token window is shared by input, thinking and
output. BeamWeaver follows continuation checkpoints automatically for ordinary
invocations, collected responses, and text/typed streams. You receive one combined
reply with all content, thought signatures, tool calls, and usage. The default
output budget is 65,536 tokens; set `max_output_tokens:` higher for longer work,
up to the shared context limit minus your input. `MAX_TOKENS` stops generation:
BeamWeaver never raises the budget you selected.

Argon uses implicit caching only. `cached_content:` and sampling controls are
rejected by its strict profile. Current input/cached-input/output rates are
$2/$0.10/$10 per million tokens through November 30, 2026, then $4/$0.20/$20.
Use `UsageCost.calculate/3` with `at:` for a dated estimate. See Google's
[model specification](https://ai.google.dev/gemini-api/docs/models/gemini-4-argon)
and [pricing](https://ai.google.dev/gemini-api/docs/pricing).

The client uses streaming HTTP internally, even when the caller wants one final
reply; Argon model constructors default to a 20-minute timeout per request. It preserves the original
request across hops and sums their billed usage. `usage_metadata.initial_input_tokens`
is the original prompt size; `context_tokens` is that size plus all generated
thinking/output. Summarization uses context size instead of cumulative billed
tokens, which include repeated inputs.

For reliable streaming, chunks are delivered when a checkpoint commits them or
the stream finishes successfully. This can delay visible output until a checkpoint
or completion. A dropped stream resumes at its latest checkpoint, discarding
uncommitted chunks so text is not duplicated. Before any checkpoint, it retries
the original request. `max_continuation_retries:` defaults to 2 per unfinished
hop; permanent errors fail immediately. Halting enumeration cancels the active
request and prevents further hops.

Checkpoint tokens can make the wire response much larger than the visible answer.
Automatic continuation uses the stream byte limit (64 MiB by default) for each
HTTP response, rather than the ordinary transport's 5 MB limit. Explicit
`max_response_bytes:` limits still apply.

Set `automatic_continuation: false` on the model or invocation for manual control.
Then a `CONTINUATION` response is returned as `provider_pause`, and its
`response_metadata.continuation_token` can be passed as `continuation_token:`
with the original messages and generation options. Manual REST calls retain the
32,768 non-streaming / 65,536 streaming per-request defaults. See Google's
[long-decode guide](https://ai.google.dev/gemini-api/docs/generate-content/long-decode).

## Options and thinking

| Option | Purpose |
| --- | --- |
| `max_output_tokens:` / `max_tokens:` | Output budget |
| `thinking_level:` | Supported level for the chosen model |
| `thinking_budget:` | Token budget only where supported |
| `include_thoughts:` | Request returned thought summaries |
| `cached_content:` | Actual cached-content resource name |
| `safety_settings:` | Native category thresholds |
| `stop_sequences:` / `stop:` | Stop text |
| `labels:` | Labels sent at the top level of the request |
| `generation_config:` | Additional native generation controls |
| `base_url:` | Developer API root |

Newer Flash profiles restrict sampling and use thinking levels rather than
budgets. Validate the exact model's options instead of assuming all Gemini
versions accept the same controls. `Message.text/1` excludes reasoning blocks;
usage can report reasoning tokens separately.

Thinking controls are model-specific. This complete agent requests thoughts and invokes the configured model:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "google:gemini-3.8-flash", thinking_level: :high, include_thoughts: true, timeout: 120_000
  system_prompt "You are Acme's support agent."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Reply with the word ready."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

## Built-in tools

Google runs supported search/code tools on its servers. This call checks
actual grounding metadata from search:

```elixir
{:ok, searched} =
  ChatModel.invoke(
    model,
    "Use Google Search to find the official Elixir programming language website and cite it.",
    tools: [BeamWeaver.Google.Tools.google_search()]
  )

true = byte_size(Message.text(searched)) > 0
true = is_map(searched.response_metadata.grounding_metadata)
true = map_size(searched.response_metadata.grounding_metadata) > 0
```

Other helpers include URL context, Maps, code execution, file search and MCP
servers. File search needs actual store resources. A computer-use declaration
requires your application's browser/desktop executor and returned action
results; BeamWeaver does not supply that executor.

Hosted tools belong in model call options. Ordinary agent tools use the
[Tool DSL](../tools.md). Supported image/PDF tool results are carried in
Gemini function-response parts.

## Context caching

Automatic prefix caching reports usage when a hit occurs. Explicit caching
requires a resource created through Google's API. From a configured checkout,
this creates a short-lived resource, uses it and deletes it:

```elixir
root = "https://generativelanguage.googleapis.com/v1beta"
headers = [{"x-goog-api-key", System.fetch_env!("GOOGLE_API_KEY")}]
policy = String.duplicate("Returns are accepted within 30 days. Opened items must include all parts.\n", 400)

created =
  Req.post!(root <> "/cachedContents",
    headers: headers,
    json: %{model: "models/gemini-3.5-flash", ttl: "300s", contents: [%{role: "user", parts: [%{text: policy}]}]},
    retry: false,
    receive_timeout: 60_000
  )

true = created.status in 200..299
name = Map.fetch!(created.body, "name")

try do
  {:ok, cached} =
    BeamWeaver.Models.init_chat_model("google:gemini-3.5-flash",
      cached_content: name,
      max_tokens: 1_024,
      timeout: 60_000
    )

  {:ok, reply} = ChatModel.invoke(cached, "How many days do I have to return an item?")
  true = Message.text(reply) =~ "30"
  true = get_in(reply.usage_metadata, [:input_token_details, :cache_read]) > 0
after
  deleted = Req.delete!(root <> "/" <> name, headers: headers, retry: false)
  true = deleted.status in 200..299
end
```

The application owns resource creation/expiry/deletion; the model option only
references it. `prompt_caching` adds no marker for Gemini. See the official
[caching API](https://ai.google.dev/api/caching) for resource constraints.

## Media and token counting

Gemini profiles support text, image, PDF, audio and video inputs. Use actual
supported media bytes or resources, not fabricated IDs. [Messages](../messages.md)
explains content blocks; the model's profile validates capability compatibility.

```elixir
{:ok, tokens} = BeamWeaver.Google.ChatModel.count_tokens(model, "Check order A-1001.")
true = is_integer(tokens) and tokens > 0
```

Counting sends the same input, system instructions, tools, cached-content reference
and generation options as generation, wrapped in `generateContentRequest` when
needed.

Counting calls the provider but does not generate an answer. Safety filtering
can affect completion even on HTTP success; inspect the provider outcome and
terminal stream events.

## Models

Limits are local profile data. A dash means not applicable or not recorded,
not an unlimited allowance.

| Model | Input / output tokens | Operations and capabilities |
| --- | --- | --- |
| `google:gemini-3.1-flash-lite` | 1,048,576 / 65,536 | chat; text, image, PDF, audio, video; tools; structured output; reasoning |
| `google:gemini-3.1-pro-preview` | 1,048,576 / 65,536 | chat; text, image, PDF, audio, video; tools; structured output; reasoning |
| `google:gemini-3.5-flash` | 1,048,576 / 65,536 | chat; text, image, PDF, audio, video; tools; structured output; reasoning |
| `google:gemini-3.5-flash-lite` | 1,048,576 / 65,536 | chat; text, image, PDF, audio, video; tools; structured output; reasoning |
| `google:gemini-3.6-flash` | 1,048,576 / 65,536 | chat; text, image, PDF, audio, video; tools; structured output; reasoning |
| `google:gemini-3.7-flash` | 1,048,576 / 65,536 | chat; text, image, PDF, audio, video; tools; structured output; reasoning |
| `google:gemini-3.8-flash` | 1,048,576 / 65,536 | chat; text, image, PDF, audio, video; tools; structured output; reasoning |
| `google:gemini-4-argon` | 1,048,576 / 1,048,576 | chat; text, image, PDF, audio, video; tools; structured output; reasoning |


Gemini 3.5 Flash is served by 3.6 Flash, and 3.7 Flash by 3.8 Flash; their
profiles use the serving models' capabilities and rates. Preview identifiers
and aliases can have different availability from stable models. See Google's
[model reference](https://ai.google.dev/gemini-api/docs/models) and
[retirement schedule](https://ai.google.dev/gemini-api/docs/deprecations).

## Further reading

[Testing](../testing.md) covers deterministic application tests and replay. Live requests above check the configured Google integration.
