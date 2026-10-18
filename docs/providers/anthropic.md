# Anthropic

BeamWeaver calls Claude models through Anthropic's Messages API with
`BeamWeaver.Anthropic.ChatModel`. It supports extended thinking and effort,
prompt caching, on-demand compaction, token counting, and Anthropic's server
tools such as web search and code execution (`BeamWeaver.Anthropic.Tools`).

## Setup

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :anthropic, api_key: System.get_env("ANTHROPIC_API_KEY")
```

Export `ANTHROPIC_API_KEY`. The same group takes `base_url:` to send every
request through a proxy or gateway.

## Models

| Model | Kind | Input tokens | Output tokens | Tools | Structured output | Reasoning | Inputs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `anthropic:claude-fable-5` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-fable-5-1` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-haiku-4-5` | chat | 200,000 | 64,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-haiku-4-5-20251001` | chat | 200,000 | 64,000 | yes | — | yes | text, image, PDF |
| `anthropic:claude-haiku-5-5` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-mythos-5` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-mythos-5-1` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-opus-4-5` | chat | 200,000 | 64,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-opus-4-5-20251101` | chat | 200,000 | 64,000 | yes | — | yes | text, image, PDF |
| `anthropic:claude-opus-4-6` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-opus-4-7` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-opus-4-8` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-opus-5` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-opus-5-5` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-sonnet-4-5` | chat | 200,000 | 64,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-sonnet-4-5-20250929` | chat | 200,000 | 64,000 | yes | — | yes | text, image, PDF |
| `anthropic:claude-sonnet-4-6` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-sonnet-5` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |
| `anthropic:claude-sonnet-5-5` | chat | 1,000,000 | 128,000 | yes | yes | yes | text, image, PDF |

Ids without a date, such as `claude-haiku-4-5`, follow Anthropic's latest
snapshot of that model; dated ids are pinned.

Claude Mythos 5 and 5.1 require access through Anthropic's verification
programs. Their profiles describe the API contract; they are not available
to every account. Use Fable for the corresponding generally available model.
See Anthropic's [model availability](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model).

## Usage

Name the model on the agent's `model` line, with any options after it:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-haiku-4-5", max_tokens: 4_096, timeout: 120_000
  system_prompt "You are Acme's support agent. Answer in two sentences."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
```

Tools, middleware and memory work as in [Agents](../agents.md). To call the
model without an agent, build it with `BeamWeaver.Models.init_chat_model/2`
(see [Models](../models.md)):

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("anthropic:claude-haiku-4-5")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Write a one-line apology for a late order.")
BeamWeaver.Core.Message.text(reply)
```

## Options

| Option | What it does |
| --- | --- |
| `max_tokens` | Output cap. Defaults to the model's maximum output, such as 64,000 for Claude Haiku 4.5. `max_output_tokens` is the same option. |
| `thinking` | Extended thinking: `%{type: :enabled, budget_tokens: 4_096}` or `%{type: :adaptive}`. See below. |
| `reasoning_effort` | How much the model thinks and writes, from `:low` to `:max`, on the models that take it; `effort` is the same option. See below. |
| `cache_control` | `%{type: :ephemeral}` caches the request prefix. See below. |
| `stop_sequences` | Strings that end the answer; `stop` is the same option. |
| `top_k` | Sampling, with `temperature` and `top_p`, on models that allow it. |
| `metadata` | `%{user_id: "..."}`: an opaque id for your end user, which Anthropic uses to detect abuse. It is Anthropic's only metadata field, so another key, or a `user_id` that isn't a string of at most 512 characters, returns an `:unsupported_model_param` error before the request. Trace data goes in `trace_metadata:` (see [Tracing](../tracing.md#name-and-tag-a-run)). |
| `betas` | Extra `anthropic-beta` headers. BeamWeaver adds the ones its own features need. |
| `base_url` | The API root, for a proxy. Defaults to `https://api.anthropic.com`. |
| `endpoint` | The full Messages URL, for a proxy. Token counting follows it. |

The options shared by every provider, such as `timeout`, are on
[Providers](../providers.md#options-for-every-provider).

## Thinking and effort

Claude can think before it answers. Older models, such as Claude Haiku 4.5 and
Sonnet 4.6, take a token budget:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-sonnet-4-6", thinking: %{type: :enabled, budget_tokens: 4_096}, timeout: 120_000
  system_prompt "You are Acme's support agent."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Reply with the word ready."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

Newer models, from Claude Opus 4.7 and the 5.x family on, decide how much to
think themselves. Steer them with `reasoning_effort:` instead, which turns
adaptive thinking on, with its summary in the reply, unless you set
`thinking:` yourself. BeamWeaver rejects a manual `budget_tokens`, a
`temperature` other than 1, and `top_k` for them before the request is sent:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-opus-5-5", reasoning_effort: :high, timeout: 120_000
  system_prompt "You are Acme's support agent."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Reply with the word ready."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

Claude Opus 4.5 and 4.6 and Sonnet 4.6 take an effort alongside their
thinking budget; Haiku 4.5 and Sonnet 4.5 take none. A model's profile lists
its levels in `reasoning_effort_levels`, and BeamWeaver rejects one it doesn't
list before the request is sent.

Claude Opus 5.5, Sonnet 5.5, Fable 5.1 and Mythos 5.1 can't turn thinking
off: they reject `thinking: %{type: :disabled}`. Thinking comes back as
`%{type: :reasoning}` blocks in the reply's `content`;
`BeamWeaver.Core.Message.text/1` skips them. Keep them in the history you send
back, as agents do: Claude needs them to continue after a tool call.

## Prompt caching

Anthropic caches only what you mark. In an agent, `prompt_caching true` marks
the system prompt as eligible for caching. Minimum prompt lengths and cache
availability still apply; a short tutorial prompt may have no cache usage
metadata. Inspect reported cache reads rather than assuming a cache hit:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-haiku-4-5", timeout: 120_000
  system_prompt "You are Acme's support agent. Follow the refund policy below. ..."
  prompt_caching true
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Reply with the word ready."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

On a direct call, set `cache_control: %{type: :ephemeral}` on the model to
cache the whole prefix, or mark one content block:

Run this example from a repository checkout, using the bundled
[example fixtures](https://github.com/caudena/beam_weaver/tree/master/examples/fixtures).

```elixir
alias BeamWeaver.Core.{ContentBlock, Message}

policy = File.read!("examples/fixtures/refund_policy.md")

messages = [
  Message.user([ContentBlock.text(policy, %{cache_control: %{type: "ephemeral"}})]),
  Message.user("Can I return an opened item?")
]

{:ok, model} = BeamWeaver.Models.init_chat_model("anthropic:claude-haiku-4-5")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, messages)
Map.get(reply.usage_metadata, :input_token_details, %{})
```

Cache reads show up in `usage_metadata.input_token_details.cache_read`. See
[Caching](../caching.md).

## Server tools

Anthropic runs hosted tools such as web search and code execution on its
servers. `BeamWeaver.Anthropic.Tools` builds the declarations and BeamWeaver
adds any beta header they need:

```elixir
alias BeamWeaver.Anthropic.Tools

{:ok, model} = BeamWeaver.Models.init_chat_model("anthropic:claude-sonnet-4-6", timeout: 120_000)

{:ok, reply} =
  BeamWeaver.Core.ChatModel.invoke(model, "Which carriers deliver to Iceland?",
    tools: [Tools.web_search(), Tools.code_execution()]
  )
```

Other hosted-tool helpers include `web_fetch/1`, `tool_search/1`,
`mcp_toolset/1` and `advisor/1`. A tool a model doesn't offer, such as web fetch on Claude
Opus 5, is rejected before the request.

`bash/1`, `text_editor/1`, `memory/1` and `computer/1` declare client tools.
Your application must execute their requested actions and return results;
the declaration alone does not implement them. Anthropic's
[Bash tool guide](https://platform.claude.com/docs/en/agents-and-tools/tool-use/bash-tool)
describes that client-side loop. For BeamWeaver-managed file and shell tools,
see [Filesystem](../filesystem.md) and [Sandboxes](../sandboxes.md).

Computer-use declarations also need display dimensions and a model-compatible
tool revision: the `computer/1` default is for Haiku 4.5; Sonnet 4.6 needs
`type: "computer_20251124"`. Claude 5.5 uses `computer_toolset/1` instead.

An agent offers server tools next to its own when they are in its model
options:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-sonnet-4-6", tools: [BeamWeaver.Anthropic.Tools.web_search()], timeout: 120_000
  system_prompt "You are Acme's support agent. Search the web for carrier outages."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Reply with the word ready."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

The next request sends a reply's server tool calls and results back exactly
as Anthropic returned them, whether the reply was streamed or not.

## Compaction

Claude Opus 5.5 and Sonnet 5.5 can summarize a long conversation into one
compaction message. Send the history with `compaction:`, then continue from
the summary instead of the full history:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

{:ok, model} = BeamWeaver.Models.init_chat_model("anthropic:claude-opus-5-5", timeout: 120_000)

history = [
  Message.user("My order A-1001 arrived damaged."),
  Message.assistant("Sorry to hear that. I can refund or replace it.")
]

{:ok, summary} = ChatModel.invoke(model, history, compaction: %{type: :summarize, instructions: "Keep order ids."})
{:ok, reply} = ChatModel.invoke(model, [summary, Message.user("Please replace it.")])
```

The summary has `status: "compaction"`; send it back unchanged. A compaction
request can't end on an unanswered tool call, force a tool choice or ask for
structured output. To keep agent conversations short, see
[Context Management](../context_management.md).

## Token counting

`BeamWeaver.Anthropic.ChatModel.count_tokens/3` asks Anthropic how many input
tokens a request uses, before you send it:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("anthropic:claude-haiku-4-5")
{:ok, tokens} = BeamWeaver.Anthropic.ChatModel.count_tokens(model, "Where is my order A-1001?")
```

## Limitations

- Only Anthropic's own API: no Amazon Bedrock or Google Vertex AI routing.
- Claude Opus 5.5, Sonnet 5.5, Fable 5.1 and Mythos 5.1 accept only `:auto`
  or `:none` tool choice, so the structured-output tool strategy offers the
  schema tool on them without forcing it.
- The Files API and Anthropic's managed-agent resources have no BeamWeaver
  wrapper.

## Testing

In tests, use `"fake:chat"` instead of a Claude model; it needs no key (see
[Testing](../testing.md)). To check the exact requests your code sends,
answer them from a cassette with `transport: BeamWeaver.Transport.Replay`
and `transport_opts: [cassette_path: "test/cassettes/anthropic.yml"]`;
[Replay provider responses](../testing.md#replay-provider-responses) shows
how to write one.

## Reference

- [Claude structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs): provider API contract

- [`BeamWeaver.Anthropic`](https://hexdocs.pm/beam_weaver/BeamWeaver.Anthropic.html): constructors
- [`BeamWeaver.Anthropic.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Anthropic.ChatModel.html): the Messages API model and token counting
- [`BeamWeaver.Anthropic.Tools`](https://hexdocs.pm/beam_weaver/BeamWeaver.Anthropic.Tools.html): server tool declarations
- [`BeamWeaver.Core.ContentBlock`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.ContentBlock.html): content blocks, including cache marks
