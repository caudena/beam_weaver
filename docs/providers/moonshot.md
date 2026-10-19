# Moonshot (Kimi)

Moonshot's Kimi integration uses Chat Completions. Thinking controls, forced
tool choice and structured output vary by model generation; choose the model
and options together. The adapter exposes Chat Completions and token estimation.
Moonshot's Responses, Anthropic-compatible Messages and standalone Search/Fetch
APIs require a separate client.

## Setup and first request

```elixir
import Config
config :beam_weaver, :moonshot, api_key: System.get_env("MOONSHOT_API_KEY") || System.fetch_env!("KIMI_API_KEY")
```

Place configuration in your application's runtime file, then run:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

{:ok, model} =
  BeamWeaver.Models.init_chat_model("moonshot:kimi-k2.6",
    thinking: %{type: :disabled},
    max_tokens: 512,
    timeout: 120_000
  )

{:ok, reply} = ChatModel.invoke(model, "Explain parcel tracking in one sentence.")
true = byte_size(Message.text(reply)) > 0
true = reply.usage_metadata.total_tokens > 0
```

Use `moonshot:` explicitly. Long reasoning tasks need appropriate provider
and whole-run timeouts. Preserve full returned messages for subsequent tool rounds.

## Model-specific behavior

| Family | Thinking and tools |
| --- | --- |
| K2.6 | Thinking can be enabled/disabled; forced/named tools require thinking off |
| K2.7 Code | Thinking remains enabled; forced tool choice is unavailable |
| K3 | Always reasons; `reasoning_effort:` accepts `:low`, `:high`, or `:max` (default); supports required tool choice and dynamic tools |

Sampling values are fixed for these profiles; unsupported temperature/top-p
values fail locally. `max_tokens:` maps to the native completion budget.
`base_url:` chooses the native root/gateway. Request metadata is unsupported;
use `trace_metadata:` for application tracing. `logprobs:`, `top_logprobs:`
and `prediction:` pass through to Chat Completions.

## Tools on K3

Dynamic tool messages add tools partway through a conversation. This example
checks the returned call and executes it locally:

```elixir
tool =
  BeamWeaver.Core.Tool.from_function!(
    name: "delivery_day",
    description: "Read the delivery day for an order.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"order_id" => %{"type" => "string"}},
      "required" => ["order_id"]
    },
    handler: fn %{"order_id" => "A-1001"}, _ -> {:ok, "Thursday"} end
  )

{:ok, k3} = BeamWeaver.Models.init_chat_model("moonshot:kimi-k3", max_tokens: 4_096, timeout: 120_000)
messages = [Message.user("Call delivery_day for A-1001."), BeamWeaver.Moonshot.Tools.dynamic_message([tool])]
{:ok, requested} = ChatModel.invoke(k3, messages)
[call] = requested.tool_calls
"delivery_day" = call.name
%{"order_id" => "A-1001"} = call.args
{:ok, result} = BeamWeaver.Core.Tool.invoke(tool, call)
"Thursday" = Message.text(result)
```

Other Kimi models reject this dynamic declaration mechanism. Use ordinary
agent tools for a static tool set. The native `$web_search` helper has a
restricted K2.6 nonthinking contract and is not an agent-managed search tool;
do not assume adding it gives an agent a working web-search executor.

## Structured output and caching

K3 and K2.7 Code use JSON Schema response formats. K2.6 uses JSON-object mode
with schema instructions and local checks. The schema-tool strategy can force
a call only where the model permits it. See
[Structured Output](../structured_output.md) for the validation boundary.

`prompt_caching` supplies a prompt cache key. Hits are observed through
`usage_metadata.input_token_details.cache_read`, not guaranteed by configuration.
K3 also accepts `prompt_cache_options: %{mode: "implicit", ttl: "1h"}`; the
default TTL is `"5m"`. Cache writes are reported separately from reads, with
TTL breakdowns retained from response headers for billing.

## Images and video

Use inline data URLs or `ms://` references from actual Moonshot uploads.
Arbitrary remote media URLs are not accepted by this integration. From a
checkout with the bundled fixtures, or save [the video](../assets/fixtures/red-square.mp4)
as `examples/fixtures/red-square.mp4` in your application:

```elixir
alias BeamWeaver.Core.ContentBlock

question =
  Message.user([
    ContentBlock.text("What single colour fills this video?"),
    ContentBlock.video(url: "data:video/mp4;base64," <> Base.encode64(File.read!("examples/fixtures/red-square.mp4")))
  ])

{:ok, reply} = ChatModel.invoke(k3, [question])
true = reply |> Message.text() |> String.downcase() |> String.contains?("red")
```

Images returned by tools are carried in a following user message alongside
the textual tool result. PDF/file inputs are not supported. Token estimates
use `Moonshot.ChatModel.count_tokens/3`. Files, Batch and Balance management
require Moonshot's API outside this wrapper.

## Models

Limits are local profile data. A dash means not applicable or not recorded,
not an unlimited allowance.

| Model | Input / output tokens | Operations and capabilities |
| --- | --- | --- |
| `moonshot:kimi-k2.6` | 262,144 / — | chat; text, image, video; tools; structured output; reasoning |
| `moonshot:kimi-k2.7-code` | 262,144 / — | chat; text, image, video; tools; structured output; reasoning |
| `moonshot:kimi-k2.7-code-highspeed` | 262,144 / — | chat; text, image, video; tools; structured output; reasoning |
| `moonshot:kimi-k3` | 1,048,576 / 1,048,576 | chat; text, image, video; tools; structured output; reasoning |


Profiles describe local compatibility. Pin the model you have validated and
review replacement guidance for discontinued identifiers; changing a model
is an application decision, not a silent compatibility fallback.

## Further reading

The official [Kimi tool-call guide](https://platform.kimi.ai/docs/guide/use-kimi-api-to-complete-tool-calls) describes native tool rounds. [Testing](../testing.md) covers deterministic application tests.
