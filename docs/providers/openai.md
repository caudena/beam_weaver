# OpenAI

BeamWeaver uses Responses by default and also supports Chat Completions,
embeddings, typed decisions, image generation and moderation. A shared provider
name does not mean those endpoints accept the same fields or tool types.

## Setup and first request

Save this in your application's `config/runtime.exs`:

```elixir
import Config
config :beam_weaver, :openai, api_key: System.fetch_env!("OPENAI_API_KEY")
```

```elixir
alias BeamWeaver.Core.{ChatModel, Message}
{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000)
{:ok, reply} = ChatModel.invoke(model, "Explain parcel tracking in one sentence.")
true = byte_size(Message.text(reply)) > 0
true = reply.usage_metadata.total_tokens > 0
```

The same identifier works in an agent's model declaration. `organization:`
and `project:` select account billing context; `base_url:` changes the API
root. Keep trace labels separate from native request metadata.

## Responses or Chat Completions

Responses carries native output items, hosted tools and continuation IDs.
Use Chat Completions when your target endpoint requires that contract:

```elixir
{:ok, chat} =
  BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", api: :chat_completions, max_tokens: 256, timeout: 60_000)

{:ok, reply} = ChatModel.invoke(chat, "Write a brief greeting.")
true = byte_size(Message.text(reply)) > 0
```

Some newer models restrict Chat Completions tools: Astra and GPT-6.1 Sol
require Responses; GPT-5.6, GPT-6 Sol and Luna require nonreasoning mode for
that endpoint's tools. Local profiles validate these combinations. Hosted
tools and reasoning summaries use Responses. Tool-returned media on Chat
Completions is carried in a following user message rather than a text-only
tool result.

## Options

| Option | Meaning |
| --- | --- |
| `api:` | `:responses` or `:chat_completions` |
| `reasoning_effort:` / `reasoning:` | Model-supported effort and reasoning controls |
| `verbosity:` | Supported low/medium/high answer verbosity |
| `max_tokens:` | Native output-token cap |
| `service_tier:` | Provider processing tier |
| `store:` | Remote response storage policy |
| `use_previous_response_id:` | Continue eligible stored Responses replies |
| `prompt_cache_key:`, `prompt_cache_options:` | Prefix cache controls where supported |
| `metadata:` | Native OpenAI stored-response metadata |
| `endpoint:` | Full endpoint override |

Metadata is bounded to 16 string pairs with documented key/value limits.
Application trace labels use `trace_metadata:` instead. Unknown/unsupported
parameters fail locally. Sampling support depends on the model and reasoning
mode; do not copy temperature options indiscriminately between generations.

## Reasoning and continuation

Set only effort levels accepted by the selected profile. Returned reasoning
lives in content blocks and is excluded from `Message.text/1`. Preserve full
messages for replay. Reasoning can consume the output budget before visible
text, so choose token/time limits appropriate to the task.

GPT-6 Responses can accept configuration-update input blocks for supported
mid-conversation effort changes. Additional-tool input blocks can add tools
at a point in the conversation. These are native Responses features, not
portable chat options. A configuration update is carried in conversation
content; ordinary `reasoning_effort:` configures the model request itself.

With `use_previous_response_id`, BeamWeaver continues only compatible stored
replies. Other-provider replies and `store: false` replies remain full history.
Remote continuation does not replace your application's checkpoint ownership.

Configure reasoning effort for an actual call, and read only its visible answer:

```elixir
{:ok, reasoning} =
  BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", reasoning_effort: :low, max_tokens: 512, timeout: 60_000)

{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(reasoning, "What is 19 + 23? Give the result briefly.")
true = BeamWeaver.Core.Message.text(reply) =~ "42"
```

## Built-in tools

Hosted tools run on OpenAI's infrastructure. This call verifies a search item
in the actual response:

```elixir
{:ok, searched} =
  ChatModel.invoke(
    model,
    "Use web search to find the official Elixir programming language website. Return its URL.",
    tools: [BeamWeaver.OpenAI.ToolCalling.web_search()]
  )

true = byte_size(Message.text(searched)) > 0
true = Enum.any?(List.wrap(searched.content), &(Map.get(&1, :type) == :web_search_call))
```

Other helpers describe code interpreter, file search, image generation,
remote MCP and tool search. File search requires actual vector-store IDs;
remote MCP requires an actual server and its authorization/setup.

`apply_patch` and custom tools declare client actions. Your application must
execute requests and send results; adding the declaration does not implement
a file editor. Agent `tools` execute through BeamWeaver; native hosted tools
belong in model call options. See [Tools](../tools.md) and OpenAI's
[function-calling contract](https://developers.openai.com/api/docs/guides/function-calling).

## Prompt caching

Long eligible prefixes may be cached. `prompt_caching` derives a stable routing
key; explicit prompt-cache options are model-specific. Inspect actual
`input_token_details.cache_read` usage to establish a hit. Short examples can
return zero. [Caching](../caching.md) links a repeated-call example and explains
invalidation versus full-answer caching.

The agent declaration configures caching hints. Measure the returned cache-read count; this short call is not expected to force a cache hit:

```elixir
defmodule MyApp.CachedPolicyAgent do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
  system_prompt "Refunds take five business days. Answer briefly from this policy."
  prompt_caching true
end

{:ok, result} = MyApp.CachedPolicyAgent.invoke(%{messages: ["How long do refunds take?"]})
reply = List.last(result.messages)
true = byte_size(BeamWeaver.Core.Message.text(reply)) > 0
IO.inspect(get_in(reply.usage_metadata, [:input_token_details, :cache_read]) || 0, label: "Cached input tokens")
```

## Compact a conversation

The standalone compaction endpoint accepts the full current input window and
returns the next window. It is separate from graph checkpoints:

```elixir
client = BeamWeaver.OpenAI.Client.new(timeout: 120_000)
input = [%{"role" => "user", "content" => "Remember order A-1001 arrives Thursday. Acknowledge briefly."}]

{:ok, initial} =
  BeamWeaver.OpenAI.Client.responses(client, %{
    "model" => "gpt-5.4-mini",
    "input" => input,
    "max_output_tokens" => 128,
    "store" => false
  })

{:ok, compacted} =
  BeamWeaver.OpenAI.Client.compact(client, %{
    "model" => "gpt-5.4-mini",
    "input" => input ++ initial["output"]
  })

true = Enum.any?(compacted["output"], &(&1["type"] == "compaction"))

{:ok, continued} =
  BeamWeaver.OpenAI.Client.responses(client, %{
    "model" => "gpt-5.4-mini",
    "max_output_tokens" => 256,
    "input" => compacted["output"] ++ [%{"role" => "user", "content" => "Which order arrives on which day?"}]
  })

{:ok, continued_message} = BeamWeaver.OpenAI.Messages.response_to_message(continued)
true = Message.text(continued_message) =~ "A-1001"
true = String.downcase(Message.text(continued_message)) =~ "thursday"
```

Keep the complete returned output, including retained messages and opaque
compaction items. `Client.compact_response/4` can first retrieve the full
input/output of an accessible stored response. See OpenAI's
[compaction contract](https://developers.openai.com/api/docs/guides/compaction).

## Embeddings

```elixir
{:ok, embeddings} = BeamWeaver.Models.init_embeddings("openai:text-embedding-3-small", dimensions: 512)
{:ok, vector} = BeamWeaver.Core.EmbeddingModel.embed_query(embeddings, "When will my refund arrive?")
512 = length(vector)
true = Enum.all?(vector, &is_number/1)
```

Use the same dimensions/model for documents and queries. [Retrieval](../retrieval.md)
checks relevance with real embeddings; [Storage](../storage.md) covers pgvector.

## Decisions

GPT-6 Luna's Decisions integration returns typed answers/probabilities:

```elixir
alias BeamWeaver.OpenAI.Decisions.Question
{:ok, decision_model} = BeamWeaver.Models.init_decision_model("openai:gpt-6-luna", timeout: 60_000)

{:ok, response} =
  BeamWeaver.Core.DecisionModel.invoke(decision_model, %{
    state: "Checkout crashes for every customer. Nobody can pay.",
    questions: %{
      team:
        Question.choice(
          instructions: "Which team owns fixing this software outage?",
          choices: %{"engineering" => "Software failures and outages", "billing" => "Invoice corrections"}
        )
    }
  })

"engineering" = response.answers["team"].choice
```

Predicate questions return a probability; choice questions return choice,
confidence and probabilities; score questions return an expected zero-based
level. Handle refusals explicitly. State can contain supported text/images;
unsupported media must first be represented appropriately. Decisions usage
and billing differ from chat output; inspect the returned decision response
rather than reading it as an assistant message.

Predicate and score questions share the same typed decision request. Their fields differ from the choice result above:

```elixir
{:ok, assessment} =
  BeamWeaver.Core.DecisionModel.invoke(decision_model, %{
    state: "Checkout is completely broken for every customer. Nobody can buy anything.",
    questions: %{
      urgent: Question.predicate(instructions: "Is this an urgent service outage?"),
      severity:
        Question.score(
          instructions: "Rate how much purchasing is affected.",
          levels: ["Not affected", "Partly affected", "Completely blocked"]
        )
    }
  })

IO.inspect(assessment.answers, label: "Typed predicate and score answers")
true = assessment.answers["urgent"].probability > 0.5
true = assessment.answers["severity"].score > 1.5
```

## Images and moderation

Image generation is a separate endpoint. This verifies returned bytes rather
than treating a successful response tuple as an image:

```elixir
{:ok, response} = BeamWeaver.OpenAI.generate_image("A plain red square on a white background", size: "1024x1024")
[%{"b64_json" => encoded} | _] = response["data"]
{:ok, bytes} = Base.decode64(encoded)
true = byte_size(bytes) > 1_000
```

`generate_image/2` accepts `size:`, `quality:`, `background:`, `output_format:`,
`output_compression:`, `n:`, `moderation:` and `safety_identifier:`. Legacy
`response_format:`, `style:` and `user:` fields are passed through where the
selected image model supports them.

`OpenAIModeration` middleware checks configured input/output text through the
moderation endpoint. It is separate from tool authorization and stream
redaction; [Guardrails](../guardrails.md) explains those boundaries.

## Models

Limits are local profile data. A dash means not applicable or not recorded,
not an unlimited allowance.

| Model | Input / output tokens | Operations and capabilities |
| --- | --- | --- |
| `openai:gpt-4.1` | 1,047,576 / 32,768 | chat; text, image, PDF; tools; structured output |
| `openai:gpt-5` | 400,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5-mini` | 400,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5-nano` | 400,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5.4` | 1,050,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5.4-mini` | 400,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5.4-nano` | 400,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5.4-pro` | 1,050,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5.5` | 1,050,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5.5-pro` | 1,050,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5.6-luna` | 1,050,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5.6-sol` | 1,050,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-5.6-terra` | 1,050,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-6-astra` | 1,050,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-6-luna` | 1,050,000 / 128,000 | chat, decision; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-6-sol` | 1,050,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:gpt-6.1-sol` | 922,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `openai:text-embedding-3-large` | 8,191 / — | embedding; text |
| `openai:text-embedding-3-small` | 8,191 / — | embedding; text |


GPT-5, GPT-5 Mini and GPT-5 Nano are scheduled to retire on December 11, 2026;
GPT-4.1 on January 14, 2027; and GPT-5.4 Nano on April 1, 2027. Their profiles
retain support until retirement and include recommended replacements. See
OpenAI's [deprecation notices](https://developers.openai.com/api/docs/deprecations).

Profiles include aliases and access-controlled models; account access is not
implied. Azure routing and OpenAI managed-agent resources are outside this
integration. The operations described on this page are the implemented
integration; other OpenAI services require their own client integration.

## Further reading

Use [Testing](../testing.md) for scripted model behavior and replay. The examples above use the native endpoints described alongside each operation.
