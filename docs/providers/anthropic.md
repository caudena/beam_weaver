# Anthropic

Use Claude through Anthropic's Messages API. BeamWeaver preserves native
thinking and server-tool blocks for continuation and supports structured
answers, caching, token counting and supported compaction requests.

## Setup and first request

```elixir
import Config
config :beam_weaver, :anthropic, api_key: System.fetch_env!("ANTHROPIC_API_KEY")
```

Save configuration in your runtime file, then run:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}
{:ok, model} = BeamWeaver.Models.init_chat_model("anthropic:claude-haiku-4-5", max_tokens: 512, timeout: 60_000)
{:ok, reply} = ChatModel.invoke(model, "Explain parcel tracking in one sentence.")
true = byte_size(Message.text(reply)) > 0
true = reply.usage_metadata.total_tokens > 0
```

Use the same identifier in an agent module. Set explicit output/time budgets;
the provider's maximum output is usually excessive for a short application task.

## Thinking and effort

Budget-based thinking and adaptive thinking are different model contracts.
Haiku 4.5 and some earlier models accept enabled thinking with a token budget;
newer families use adaptive thinking and supported effort levels. Some current
models cannot disable thinking. Profiles expose accepted combinations.

Preserve full returned messages, including signatures and native thinking
blocks, across tool rounds. `Message.text/1` is for display, not lossless history.
Reasoning and visible answer tokens both affect the requested output budget.

For a model with a thinking budget, configure the budget and make an actual request:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-sonnet-4-6", thinking: %{type: :enabled, budget_tokens: 4_096}, timeout: 120_000
  system_prompt "You are Acme's support agent."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Reply with the word ready."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

For adaptive thinking models, choose an effort level accepted by that model:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-opus-5-5", reasoning_effort: :high, timeout: 120_000
  system_prompt "You are Acme's support agent."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Reply with the word ready."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

## Options

| Option | Purpose |
| --- | --- |
| `max_tokens:` | Output cap; max_output_tokens is an alias |
| `thinking:` | Budgeted/adaptive/disabled mode where supported |
| `reasoning_effort:` / `effort:` | Profile-supported effort |
| `cache_control:` | Prefix cache marking |
| `stop_sequences:` / `stop:` | Stop text |
| `temperature:`, `top_p:`, `top_k:` | Only combinations accepted by the model |
| `metadata:` | Anthropic's native opaque user_id field |
| `betas:` | Additional beta headers; required supported-feature headers are added automatically |
| `base_url:`, `endpoint:` | Native root or Messages endpoint override |

Native metadata accepts user_id rather than arbitrary application fields.
Use trace metadata for your own labels. Adaptive-model sampling and manual
thinking-budget restrictions are validated before HTTP execution.

## Server tools

This call asks for a hosted search and checks the returned server-tool record:

```elixir
{:ok, search_model} =
  BeamWeaver.Models.init_chat_model("anthropic:claude-sonnet-4-6", max_tokens: 1_024, timeout: 120_000)

{:ok, searched} =
  ChatModel.invoke(
    search_model,
    "Use web search to find the official Elixir programming language website and return its URL.",
    tools: [BeamWeaver.Anthropic.Tools.web_search()]
  )

true = byte_size(Message.text(searched)) > 0
true = Enum.any?(List.wrap(searched.content), &(Map.get(&1, :type) == :server_tool_call))
```

Hosted helpers include search/fetch, code execution, tool search, MCP toolsets
and advisor declarations where the selected model supports them. Preserve
server results unchanged for later requests.

Bash, text editor, memory and computer declarations are **client tools**.
Your application must implement their execution loop. Computer use also
requires display dimensions and a model-compatible tool revision; a declaration
alone does not control a desktop. The helper defaults and current revisions
are documented in `BeamWeaver.Anthropic.Tools`.

For BeamWeaver-managed actions, use [Tools](../tools.md),
[Filesystem](../filesystem.md) and [Sandboxes](../sandboxes.md).

## Structured output

Use `response_schema` in an agent or direct `response_format:` with a supported
model. The request builder closes object schemas for the native contract while
preserving optional fields. Local answer validation has a narrower scope than
full JSON Schema; see [Structured Output](../structured_output.md).
Some newer Claude models allow only auto/none tool choice, so schema-tool
output cannot always be forced.

## Prompt caching

Cache-control markers make eligible prefixes cacheable; provider length and
expiry requirements still apply. `prompt_caching true` marks agent instructions.
On direct requests, cache controls can mark the prefix or content blocks.
Inspect actual cache reads; a short successful call is not a verified hit.
[Caching](../caching.md) links the repeated-call example.

Mark a stable prefix and inspect actual cache usage over repeated provider calls. The complete policy text is inline:

```elixir
alias BeamWeaver.Core.{ChatModel, ContentBlock, Message}

policy =
  String.duplicate(
    "Refunds go to the original card within five business days. Opened goods require staff review.\n",
    180
  )

messages = [
  Message.user([ContentBlock.text(policy, %{cache_control: %{type: "ephemeral"}})]),
  Message.user("How long does a refund take?")
]

model = BeamWeaver.Models.init_chat_model!("anthropic:claude-haiku-4-5", max_tokens: 256, timeout: 120_000)

usage =
  for _ <- 1..2 do
    {:ok, reply} = ChatModel.invoke(model, messages)
    true = byte_size(Message.text(reply)) > 0
    Map.get(reply.usage_metadata, :input_token_details, %{})
  end

IO.inspect(usage, label: "Provider-reported prefix cache usage")
```

## Compaction

Supported Claude 5.5 models can return a provider-native compaction message.
Keep it unchanged when continuing:

```elixir
{:ok, compacting} = BeamWeaver.Models.init_chat_model("anthropic:claude-opus-5-5", max_tokens: 2_048, timeout: 120_000)
history = [Message.user("My order ID is A-1001."), Message.assistant("I will refer to order A-1001.")]

{:ok, summary} =
  ChatModel.invoke(compacting, history, compaction: %{type: :summarize, instructions: "Preserve the order ID."})

"compaction" = summary.status
{:ok, recalled} = ChatModel.invoke(compacting, [summary, Message.user("What is my order ID?")])
true = Message.text(recalled) =~ "A-1001"
```

Compaction cannot end on an unanswered tool call or combine incompatible
forced-tool/schema requests. This native operation is separate from
BeamWeaver's [agent context policy](../context_management.md) and
[application-owned compaction engine](../compaction_engine.md).

## Token counting

```elixir
{:ok, tokens} = BeamWeaver.Anthropic.ChatModel.count_tokens(model, "Check order A-1001.")
true = is_integer(tokens) and tokens > 0
```

Token counting is a provider request, not inference. It does not establish
that the model can complete your actual tool/answer workload.

## Models

Limits are local profile data. A dash means not applicable or not recorded,
not an unlimited allowance.

| Model | Input / output tokens | Operations and capabilities |
| --- | --- | --- |
| `anthropic:claude-fable-5` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-fable-5-1` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-haiku-4-5` | 200,000 / 64,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-haiku-4-5-20251001` | 200,000 / 64,000 | chat; text, image, PDF; tools; reasoning |
| `anthropic:claude-haiku-5-5` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-mythos-5` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-mythos-5-1` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-opus-4-5` | 200,000 / 64,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-opus-4-5-20251101` | 200,000 / 64,000 | chat; text, image, PDF; tools; reasoning |
| `anthropic:claude-opus-4-6` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-opus-4-7` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-opus-4-8` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-opus-5` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-opus-5-5` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-sonnet-4-5` | 200,000 / 64,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-sonnet-4-5-20250929` | 200,000 / 64,000 | chat; text, image, PDF; tools; reasoning |
| `anthropic:claude-sonnet-4-6` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-sonnet-5` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |
| `anthropic:claude-sonnet-5-5` | 1,000,000 / 128,000 | chat; text, image, PDF; tools; structured output; reasoning |


Undated aliases can follow newer snapshots. Restricted Mythos profiles do not
imply account entitlement; check Anthropic's
[model availability](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model).
This integration targets Anthropic's API, not Bedrock or Vertex routing.
Files/managed-agent resource management is outside the wrapper.

## Further reading

The official [structured-output contract](https://platform.claude.com/docs/en/build-with-claude/structured-outputs) describes native schema constraints. [Testing](../testing.md) covers scripted behavior and replay.
