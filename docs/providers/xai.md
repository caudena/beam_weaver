# xAI

Use xAI Grok through Responses (default) or Chat Completions. Responses
preserves provider-native reasoning state and supports hosted search tools.
BeamWeaver supplies chat integration, not an xAI embedding adapter.

## Setup and first request

```elixir
import Config
config :beam_weaver, :xai, api_key: System.fetch_env!("XAI_API_KEY")
```

Put configuration in your application's runtime file, then make an actual call:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}
{:ok, model} = BeamWeaver.Models.init_chat_model("xai:grok-4.3", max_tokens: 512, timeout: 120_000)
{:ok, reply} = ChatModel.invoke(model, "Explain parcel tracking in one sentence.")
true = byte_size(Message.text(reply)) > 0
true = reply.usage_metadata.total_tokens > 0
```

The example pins its model rather than relying on a changing provider default.
The same identifier works in an agent's model declaration.

## Options and endpoint differences

| Option | Purpose |
| --- | --- |
| `api:` | Responses or Chat Completions |
| `reasoning_effort:` | A level listed by the selected model profile |
| `max_tokens:` | Output budget |
| `prompt_cache_key:` | Responses and Chat Completions cache routing |
| `safety_identifier:` | Opaque end-user identifier on either API |
| `guidelines:` | Native category/behavior instructions on either API |
| `min_p:`, `top_k:` | Responses sampling controls |
| `x_grok_conv_id:` | Conversation header used for cache routing |
| `use_previous_response_id:` | Continue eligible stored Responses history |
| `service_tier:` | Native processing tier where available |
| `base_url:` | API root/gateway |

Stop sequences are supported only on nonreasoning Chat Completions models.
Request metadata is not accepted; use trace metadata for application labels.
On Chat Completions, tool-returned images/PDFs move to a following user message;
on Responses they remain in the tool result.

## Reasoning

BeamWeaver requests encrypted reasoning content on Responses for reasoning
models and replays it unchanged. This also permits full-history continuation
with `store: false`. An explicit raw include override can replace automatic
include fields, so preserve required items when customizing requests.

Responses usage may include `context_details` for the latest server-side agent
step. BeamWeaver exposes its input-plus-output count as
`usage_metadata.context_tokens` for context budgeting while retaining cumulative
`total_tokens` for billing.

Chat Completions has no equivalent encrypted reasoning field. Do not reduce
saved messages to visible text when the next request needs provider-native
continuation state.

Choose a supported effort setting and execute the model:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "xai:grok-4.6", reasoning_effort: :low, timeout: 120_000
  system_prompt "You are Acme's support agent."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Reply with the word ready."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

## Server tools

A hosted tool executes at xAI. This example checks that search was actually
requested by the provider response, not just declared:

```elixir
{:ok, searched} =
  ChatModel.invoke(
    model,
    "Use web search to find the official Elixir programming language website and return its URL.",
    tools: [BeamWeaver.XAI.Tools.web_search()]
  )

true = byte_size(Message.text(searched)) > 0
true = Enum.any?(List.wrap(searched.content), &(Map.get(&1, :type) == :web_search_call))
```

Other implemented declarations include X search, code execution, collection/
file search and remote MCP. Account resources such as vector-store IDs must
come from actual provisioning. Chat Completions supports function tools;
use Responses for hosted search. [Tools](../tools.md) explains application-run
actions and their separate execution loop. Generated file references returned
by Chat Completions are available in `response_metadata.output_files`, including
in collected streams.

## Stored conversations

`use_previous_response_id: true` can send only new messages after a compatible
stored Responses reply. Replies from another provider/API or from `store: false`
are sent as history instead. A stored response ID is remote state; account
retention and availability apply. Keep your application's conversation data
when you need independent recovery.

Use the complete stored reply when continuing. The second call must recall the earlier order:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

{:ok, model} = BeamWeaver.Models.init_chat_model("xai:grok-4.6", timeout: 120_000)
history = [Message.user("My order number is A-1001.")]
{:ok, reply} = ChatModel.invoke(model, history, use_previous_response_id: true)

# Sends only the new question, with the id of `reply`.
{:ok, answer} =
  ChatModel.invoke(model, history ++ [reply, Message.user("Which order did I mention?")],
    use_previous_response_id: true
  )

true = Message.text(answer) =~ "A-1001"
```

## Prompt caching

The agent's `prompt_caching` declaration derives a stable key. Responses sends
its key and conversation header; Chat Completions accepts both as well. Read actual
cache usage to establish hits. The [caching guide](../caching.md) distinguishes
provider prefix caching from skipping a whole model call.

Set the caching hint on the actual Chat Completions model. Caching is still subject to provider eligibility:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "xai:grok-4.6", api: :chat_completions, timeout: 120_000
  system_prompt "Refunds take five business days. Explain the policy briefly."
  prompt_caching true
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Reply with the word ready."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

## Embeddings

Use an implemented embedding integration such as [OpenAI](openai.md#embeddings)
for retrieval alongside a Grok chat model. There is no xAI embedding model to
initialize through BeamWeaver. Image/video/voice generation APIs are also
outside this chat integration.

## Models

Limits are local profile data. A dash means not applicable or not recorded,
not an unlimited allowance.

| Model | Input / output tokens | Operations and capabilities |
| --- | --- | --- |
| `xai:grok-4.20-0309-non-reasoning` | 1,000,000 / 30,000 | chat; text, image, PDF; tools; structured output |
| `xai:grok-4.20-0309-reasoning` | 1,000,000 / 30,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `xai:grok-4.20-multi-agent-0309` | 1,000,000 / 30,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `xai:grok-4.3` | 1,000,000 / 30,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `xai:grok-4.5` | 500,000 / 30,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `xai:grok-4.6` | 500,000 / — | chat; text, image, PDF; tools; structured output; reasoning |
| `xai:grok-4.7` | 500,000 / — | chat; text, image, PDF; tools; structured output; reasoning |
| `xai:grok-build-0.1` | 256,000 / 30,000 | chat; text, image, PDF; tools; structured output; reasoning |


This is the checked-in compatibility registry, including snapshots. It does
not imply every account can invoke every identifier. Verify your selected
model with real calls and review provider capacity errors separately from
invalid requests.

## Further reading

The official [xAI tools reference](https://docs.x.ai/developers/tools/overview) describes hosted tool requirements. Use [Testing](../testing.md) for deterministic failures and replay.
