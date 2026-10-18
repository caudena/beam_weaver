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


The table is local capability metadata, not account entitlement. Preview
identifiers and aliases can have different availability from stable models.
Use a model you have exercised with your actual inputs and tools.

## Further reading

[Testing](../testing.md) covers deterministic application tests and replay. Live requests above check the configured Google integration.
