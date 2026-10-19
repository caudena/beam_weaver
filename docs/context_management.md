# Context Management

Context management decides what a model reads as conversations and tool
results grow. Choose what to preserve before the provider's context window
is exhausted. Model context is a working set; keep authoritative data in
storage or tools that can retrieve it again.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Choose a technique

| Need | Technique | Changes future saved history? |
| --- | --- | --- |
| Keep a recent request window | Trim in a model wrapper | No |
| Retain the gist of old turns | Summarization | Yes |
| Hide obsolete tool output | ContextEditing | No |
| Keep large output available without sending it all | Filesystem offloading | Yes; full data is in a file |
| Let the agent mark a task boundary | `compact_conversation` | Yes; history is archived |
| Recover after an oversized request | `overflow_recovery` | On successful recovery |
| Reduce cost of a stable prefix | Prompt caching | No; context size is unchanged |
| Isolate a large subtask | Subagents | Parent receives a concise result |

## Summarize old messages

Complete [Installation](installation.md). This example deliberately uses a
small message threshold so you can observe a real summary being created:

```elixir
defmodule MyApp.SummarizingAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Acknowledge supplied facts briefly. Retain order IDs and delivery dates."

  middleware [
    {BeamWeaver.Agent.Middleware.Summarization,
     model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000),
     trigger: {:messages, 6},
     keep: {:messages, 2}}
  ]
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "summary-demo"}}]

for fact <- ["Order A-1001 arrives Thursday.", "The delivery address is Lisbon.", "Contact me by email."] do
  {:ok, _} = MyApp.SummarizingAgent.invoke(%{messages: [fact]}, opts)
end

{:ok, result} = MyApp.SummarizingAgent.invoke(%{messages: ["What is the order ID and delivery day?"]}, opts)
summary = result.messages |> hd() |> BeamWeaver.Core.Message.text()
true = String.starts_with?(summary, "Conversation summary:")
true = summary =~ "A-1001"
true = length(result.messages) < 8
answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = answer =~ "A-1001"
true = String.downcase(answer) =~ "thursday"
```

The middleware summarizes older messages before a model call and retains the
recent window without splitting tool-call/result pairs. The summary replaces
those messages in subsequent state; older checkpoints may still retain them.
For request-only trimming, see [Conversation History](short_term_memory.md#trim-before-each-model-call).

| Option | Meaning |
| --- | --- |
| `model:` or `summarizer:` | Summary model, or a function returning text / `{:ok, text}` |
| `trigger:` | Message count, token count or fraction of a supplied context limit; a list means any trigger |
| `keep:` | Recent message/token count or fraction to preserve |
| `max_input_tokens:` | Context limit required for fraction-based middleware settings |
| `summary_prompt:` | Summary instructions; `{messages}` is replaced by source text |
| `trim_tokens_to_summarize:` | Bound the summary input; default 4,000, `nil` means all |

Defaults are a 20-message trigger and eight retained messages. A summary can
omit details; verify preservation of facts important to your application.
Summary calls have bounded retries for retryable errors. Persistent failure
returns an error without activating the proposed history change.

To summarize a history your application keeps outside an agent run, build
the middleware with `Summarization.new/1` and call
`Summarization.summarize/2`; see
[Built-in Middleware](builtin_middleware.md#summarization).

## Clear old tool results

`BeamWeaver.Agent.Middleware.ContextEditing` replaces older model-visible
results with a placeholder after its token trigger. `keep:` selects how many
recent results remain. `clear_tool_inputs:` can also remove old arguments;
`placeholder:` customizes replacement text. Saved history keeps the original
values. This is useful for verbose search results already consumed by a model.

This request-only transformation keeps the newest result and replaces the older one:

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Agent.Middleware.ContextEditing

messages = [
  Message.user("Where are A-1001 and A-1002?"),
  Message.assistant("", tool_calls: [%{id: "call_1", name: "lookup_order", args: %{"order_id" => "A-1001"}}]),
  Message.tool("Order A-1001 shipped on Monday.", tool_call_id: "call_1"),
  Message.assistant("", tool_calls: [%{id: "call_2", name: "lookup_order", args: %{"order_id" => "A-1002"}}]),
  Message.tool("Order A-1002 shipped on Tuesday.", tool_call_id: "call_2")
]

messages |> ContextEditing.clear_tool_uses(trigger: 0, keep: 1) |> Enum.map(&Message.text/1)
#=> ["Where are A-1001 and A-1002?", "", "[cleared]", "", "Order A-1002 shipped on Tuesday."]
```

## Move large tool results into files

Filesystem middleware can offload large tool results into `/large_tool_results/`
and put a preview/path in the conversation. The agent can read the file later.
Configure thresholds for your workload and choose a backend with the required
lifetime. A state-backed archive survives only as long as its saved state.

Media handling is separate: a compatible model receives images/PDFs as media,
while incompatible built-in profiles can receive omission notices. See
[Models](models.md#images-and-pdfs) and [Filesystem](filesystem.md).

The local exporter returns 5,000 sample rows. The real model receives an archive reference, and the full data remains in the filesystem:

```elixir
defmodule MyApp.Tools.OrderHistory do
  use BeamWeaver.Tool

  name "order_history"
  description "Export all orders of a customer as CSV."

  schema do
    field :customer_id, :string
  end

  @impl true
  def invoke(_tool, _input, _opts) do
    rows = for n <- 1..5_000, do: "A-#{1000 + n},shipped,2026-05-04\n"
    {:ok, IO.iodata_to_binary(["order_id,status,shipped_on\n" | rows])}
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000

  system_prompt "Call order_history once for the supplied sample customer. Then report that the export is available; do not reread it."
  tools [MyApp.Tools.OrderHistory]
  filesystem BeamWeaver.Filesystem.State.new()
end

{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["Export the sample order history for customer ada. Call order_history once."]})

tool_message = Enum.find(result.messages, &(&1.role == :tool))
true = BeamWeaver.Core.Message.text(tool_message) =~ "/large_tool_results/"

true =
  Enum.any?(result.files, fn {path, file} ->
    String.starts_with?(path, "/large_tool_results/") and file.content =~ "order_id,status,shipped_on"
  end)
```

## Let the agent compact itself

`compact_conversation true` adds a no-argument tool and automatic summarization
using the agent's model. Options can supply a different `model:` or
`summarizer:`, `minimum_messages:` and `keep_messages:`. The tool archives
replaced history under `/conversation_history/` and leaves a summary pointing
to it. Declare filesystem access if the agent should read that archive.

Automatic summarization settings belong under `summarization:`;
`summarization: false` leaves only the tool. Defaults are 20 messages before
compaction and eight retained messages. Pending compaction is checkpointed
and applied before the next model call, including after a pause/resume.
Subagents inherit enabled summarization with budgets based on their own model.

Configure model-driven compaction with an explicit summary model. This small request checks configuration; the next block triggers a compaction:

```elixir
defmodule MyApp.CompactingAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-sonnet-4-6"

  compact_conversation model: "anthropic:claude-haiku-4-5",
                       minimum_messages: 10,
                       summarization: [trigger: {:fraction, 0.8}, keep: {:messages, 20}]
end

{:ok, result} = MyApp.CompactingAgent.invoke(%{messages: ["Reply with the word ready."]})
true = is_binary(result.messages |> List.last() |> BeamWeaver.Core.Message.text())
```

This complete tool-driven example supplies enough history to compact, requires the compaction tool once, and checks the archived transcript:

```elixir
defmodule MyApp.ManualCompaction do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Compact the earlier conversation using compact_conversation, then confirm completion."

  compact_conversation model:
                         BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000),
                       minimum_messages: 4,
                       keep_messages: 2

  middleware [
    {BeamWeaver.Agent.Middleware.ToolChoice,
     choice: fn request ->
       if Enum.any?(request.messages, &(&1.role == :tool)), do: :none, else: :required
     end}
  ]
end

alias BeamWeaver.Core.Message

history = [
  Message.user("Order A-1001 arrives Thursday."),
  Message.assistant("A-1001 arrives Thursday."),
  Message.user("My contact preference is email."),
  Message.assistant("Email is preferred."),
  Message.user("Compact this earlier conversation now.")
]

{:ok, compacted} = MyApp.ManualCompaction.invoke(%{messages: history})
true = Enum.any?(compacted.files, fn {path, _} -> String.starts_with?(path, "/conversation_history/") end)
true = BeamWeaver.Core.Message.text(hd(compacted.messages)) =~ "Conversation summary:"
```

## Recover from context overflow errors

Summarization can react to a provider's context-overflow error even if its
normal trigger has not fired. It summarizes and retries once; unsuccessful
recovery does not replace saved history.

`overflow_recovery` first shrinks a large trailing batch of tool results:
large output is archived, previews replace it and oversized file reads are
clipped. Its default trailing-result budget is 5,000 tokens, configurable
with `keep: {:tokens, n}` or a model-window fraction. The reduced state is
committed only after a successful retry.

When both policies are enabled, tool-result reduction precedes summarization.
The coordinated path makes at most two retry calls with one summary. It does
not replace proactive limits. Disabling automatic summarization also disables
its overflow summarization path.

Enable bounded overflow recovery on the actual model. This small input stays below the window:

```elixir
defmodule MyApp.OverflowRecoveryAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-sonnet-4-6"
  overflow_recovery true
end

{:ok, result} = MyApp.OverflowRecoveryAgent.invoke(%{messages: ["Reply with the word ready."]})
true = is_binary(result.messages |> List.last() |> BeamWeaver.Core.Message.text())
```

## Cache the prompt prefix

`prompt_caching` configures supported provider caching. It reduces repeated
prefix processing when a cache hit occurs; it does not increase context limits.
Keep stable instructions before changing request data and inspect reported
cache-read usage. See [Caching](caching.md).

Keep stable instructions ahead of changing user input:

```elixir
defmodule MyApp.CachedPromptAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-haiku-4-5", max_tokens: 256, timeout: 60_000
  prompt_caching true
end

{:ok, result} = MyApp.CachedPromptAgent.invoke(%{messages: ["Reply with the word ready."]})
true = is_binary(result.messages |> List.last() |> BeamWeaver.Core.Message.text())
```

## Isolate work in subagents

A subagent can read a large document in its own conversation and return a
focused result. The parent avoids importing every intermediate search or file
read. Delegation still consumes model calls and needs explicit completion,
error and budget handling. See [Subagents](subagents.md).

## The Compaction Engine

For transcripts owned by your application rather than an agent checkpointer,
use [Compaction Engine](compaction_engine.md). It returns a candidate semantic
checkpoint; your application owns rendering, provider calls and atomic activation.
