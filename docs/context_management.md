# Context Management

A model only reads what fits in its context window, and every token in it
costs time and money. Context management keeps long runs small: it summarizes
old messages, clears old tool results, moves large results into files, and
recovers when a request is still too large.

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.Summarization

  model "fake:chat",
    responses: [
      "Order A-1001 shipped on Monday.",
      "It arrives on Thursday.",
      "Yes, you can change it until Wednesday.",
      "You're welcome, Ada!"
    ]

  system_prompt "You are Acme's support agent."

  middleware [
    {Summarization,
     model:
       BeamWeaver.Models.init_chat_model!("fake:chat",
         responses: ["Ada asked about order A-1001: it shipped on Monday and arrives on Thursday."]
       ),
     trigger: {:messages, 6},
     keep: {:messages, 2}}
  ]
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

for question <- ["Where is order A-1001?", "When will it arrive?", "Can I change the address?"] do
  {:ok, _result} = MyApp.SupportAgent.invoke(%{messages: [question]}, opts)
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Thanks!"]}, opts)
Enum.map(result.messages, &BeamWeaver.Core.Message.text/1)
#=> ["Conversation summary:\nAda asked about order A-1001: it shipped on Monday and arrives on Thursday.",
#    "Yes, you can change it until Wednesday.", "Thanks!", "You're welcome, Ada!"]
```

Before the fourth model call the thread had seven messages, so the
summarization middleware replaced the oldest five with a summary written by
its own model.

## Summarize old messages

`BeamWeaver.Agent.Middleware.Summarization` checks the thread before every
model call. When `trigger:` is reached, it asks its model to summarize all but
the newest messages, then saves the thread as one user message with the
summary followed by the messages it kept. It never separates a tool call from
its result.

| Option | Meaning | Default |
| --- | --- | --- |
| `model:` | The model that writes summaries, often a small one | required without `summarizer:` |
| `summarizer:` | A function that writes the summary instead: it takes the messages to summarize and returns the text, `{:ok, text}` or `{:error, error}` | none |
| `trigger:` | `{:messages, n}`, `{:tokens, n}`, or `{:fraction, f}` of `max_input_tokens:`; a list triggers on any of them | `{:messages, 20}` |
| `keep:` | How much to keep word for word: `{:messages, n}`, `{:tokens, n}` or `{:fraction, f}` | `{:messages, 8}` |
| `max_input_tokens:` | The context window of the agent's model, which fractions are taken of; required with a fraction | none |
| `summary_prompt:` | The instruction for the summary; `{messages}` is replaced with the old messages | `"Summarize this conversation:\n\n{messages}"` |

With a real provider:

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.Summarization,
   model: "openai:gpt-5.4-mini", trigger: {:tokens, 50_000}, keep: {:messages, 20}}
]
```

A summary call that fails is tried up to 3 times, a second or more apart,
unless its error says retrying can't help, such as a bad API key (see
[Models](models.md#errors)). One over the summary model's context window is
tried once more with the middle of the old messages cut out. When it still
fails, the run returns the error and the thread stays as it was.

The old messages are gone from the thread for good; only the summary carries
them on. To keep them out of the prompt but not out of the thread, trim
instead (see [Short-Term Memory](short_term_memory.md#trim-before-each-model-call)).

## Clear old tool results

Results of earlier tool calls often stop mattering once the model has used
them. `BeamWeaver.Agent.Middleware.ContextEditing` replaces all but the newest
`keep:` results with `[cleared]` in what the model sees, once the conversation
passes `trigger:` tokens. The thread keeps the full results:

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1002"}),
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1003"}),
      "All three orders shipped on Monday."
    ]

  system_prompt "You are Acme's support agent."
  tools [MyApp.Tools.LookupOrder]

  # Small numbers to show the effect; the defaults are 100,000 tokens and 3 results.
  middleware [{BeamWeaver.Agent.Middleware.ContextEditing, trigger: 20, keep: 1}]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where are orders A-1001, A-1002 and A-1003?"]})
result.messages |> Enum.filter(&(&1.role == :tool)) |> length()
#=> 3
```

`BeamWeaver.Agent.Middleware.ContextEditing.clear_tool_uses/2` applies the
same edit to a list of messages, so you can see what the last model call
received:

```elixir
alias BeamWeaver.Agent.Middleware.ContextEditing

result.messages
|> ContextEditing.clear_tool_uses(trigger: 20, keep: 1)
|> Enum.filter(&(&1.role == :tool))
|> Enum.map(&BeamWeaver.Core.Message.text/1)
#=> ["[cleared]", "[cleared]", "Order A-1003 shipped on Monday."]
```

`exclude_tools:` lists tools whose results are never cleared, and
`placeholder:` changes the replacement text.

## Move large tool results into files

An agent with a `filesystem` saves any tool result over about 20,000 tokens
(80,000 characters) to `/large_tool_results/<tool call id>` and gives the
model a preview of its first and last lines instead. The model reads the rest
with `read_file`, a page at a time, or searches it with `grep`. Results of the
file tools themselves are never moved:

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

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("order_history", %{"customer_id" => "ada"}),
      "Ada has 5,000 orders, and all of them shipped."
    ]

  system_prompt "You are Acme's support agent."
  tools [MyApp.Tools.OrderHistory]
  filesystem BeamWeaver.Filesystem.State.new()
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["How many orders does Ada have?"]})

tool_message = Enum.find(result.messages, &(&1.role == :tool))
tool_message |> BeamWeaver.Core.Message.text() |> String.split("\n") |> hd()
#=> "Tool result too large, the result of this tool call call_0_0 was saved in the filesystem at this path: /large_tool_results/call_0_0"
```

The thread keeps the preview, and the file holds the full result. A user
message over about 50,000 tokens is saved the same way, under
`/conversation_history/`. `BeamWeaver.Agent.Middleware.Filesystem` sets both
limits; see [Built-in Middleware](builtin_middleware.md) and
[Filesystem](filesystem.md).

## Let the agent compact itself

`compact_conversation` gives the agent a `compact_conversation` tool that
takes no arguments. The model calls it when it moves on to an unrelated task;
the tool summarizes all but the newest messages, and the old messages are
saved to a file under `/conversation_history/`:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Order A-1001 shipped on Monday.",
      FakeChatModel.tool_call("compact_conversation", %{}),
      "Yes, you can return the jacket within 30 days."
    ]

  system_prompt "You are Acme's support agent."
  tools [MyApp.Tools.LookupOrder]

  compact_conversation model: Models.init_chat_model!("fake:chat", responses: ["Order A-1001 shipped on Monday."]),
                       minimum_messages: 4,
                       keep_messages: 2
end

opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-43"}}]

{:ok, _first} = MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]}, opts)
{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Thanks! Can I return a jacket?"]}, opts)

result.messages |> hd() |> BeamWeaver.Core.Message.text()
#=> "Conversation summary:\nOrder A-1001 shipped on Monday."
```

In the second call the model compacted before it answered, so the thread now
starts with the summary. The tool does nothing until the thread has
`minimum_messages:` messages (default 20), and it keeps the newest
`keep_messages:` (default 8). Declare a `filesystem` as well if the agent
should be able to read the saved history back. `compact_conversation true`
uses the agent's own model for the summaries.

`compact_conversation` also turns on automatic summarization, the
`Summarization` middleware [above](#summarize-old-messages), with the same
`model:`: by default it summarizes at 20 messages and keeps the newest 8. Its
settings go in their own list under `summarization:`, and
`summarization: false` leaves only the tool:

```elixir
model "anthropic:claude-sonnet-4-6"

compact_conversation model: "anthropic:claude-haiku-4-5",
                     minimum_messages: 10,
                     summarization: [trigger: {:fraction, 0.8}, keep: {:messages, 20}]
```

A fraction here is taken of the agent model's context window. When the model
compacts, the compaction applies before the next model call, and automatic
summarization runs only if the compacted thread still reaches its trigger.
The pending compaction is saved with the thread, so a run that pauses or stops
between the tool call and the next model call applies it, once, when it
continues.
The agent's subagents summarize automatically only when the agent itself
does, and take the fraction of their own model's context window.

## Recover from context overflow errors

`overflow_recovery` is a safety net for the call right after a large batch of
tool results. When the provider rejects the request as too long, it shrinks
those trailing tool results and retries once: large results are saved to
files under `/large_tool_results/` and replaced with a short preview, and
`read_file` results are cut to their first 4,000 characters. When the retry
succeeds, the shrunk results replace the full ones in the saved thread, so
the next call doesn't overflow again; with the default
`BeamWeaver.Filesystem.State` filesystem, the saved files join the thread's
files.

```elixir
model "anthropic:claude-sonnet-4-6"
overflow_recovery true
```

It shrinks a trailing batch only when it is over 5,000 tokens;
`overflow_recovery keep: {:tokens, n}`, or `{:fraction, f}` of the model's
context window, changes that. It acts only after a request has failed, while
offloading and summarization keep requests small in the first place: use
overflow recovery in addition to them, not instead.

## Cache the prompt prefix

Prompt caching doesn't make the context smaller, but it makes a long, stable
prefix (system prompt, tools, memory files) cheaper and faster to send again.
`prompt_caching true` marks it cacheable for providers that support it:

```elixir
prompt_caching true
```

Keep the start of the prompt identical between calls to get cache hits. See
[Caching](caching.md).

## Isolate work in subagents

A subagent runs a self-contained task, such as reading a long policy, in its
own context window and returns only its final answer. The parent's thread
gets one tool result instead of every search and file read the task needed.
See [Subagents](subagents.md).

## Choose a technique

| Technique | Turn it on with | The saved thread | Extra model calls |
| --- | --- | --- | --- |
| Summarize old messages | `Summarization` middleware | Summary and newest messages | One per summary |
| Clear old tool results | `ContextEditing` middleware | Unchanged | None |
| Move large results into files | `filesystem` | Preview, full result in a file | None |
| Agent compacts itself | `compact_conversation` | Summary and newest messages | One per compaction |
| Recover from overflow | `overflow_recovery` | Preview, full result in a file | One retry |
| Cache the prompt prefix | `prompt_caching` | Unchanged | None |
| Delegate to subagents | `subagents` | Only the subagent's answer | The subagent's own |

A long-running agent usually combines several: a `filesystem` for large
results, summarization for long threads, and `overflow_recovery` as the last
resort.

## The Compaction Engine

Everything above works on an agent's own thread. If your application stores
conversations itself, for example as rows in your own tables,
`BeamWeaver.Compaction` compacts them for you: you give it the ordered
conversation and callbacks that render and summarize it, and it returns a
candidate checkpoint, the summary plus the turns to keep, for you to save in
your own transaction. It starts no processes and stores nothing. See
[Compaction Engine](compaction_engine.md).

## Reference

- [`BeamWeaver.Agent.Middleware.Summarization`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Summarization.html): summarizes old messages
- [`BeamWeaver.Agent.Middleware.ContextEditing`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ContextEditing.html): clears old tool results from the model's view
- [`BeamWeaver.Agent.Middleware.Filesystem`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Filesystem.html): file tools and offloading of large results
- [`BeamWeaver.Agent.Middleware.CompactConversation`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.CompactConversation.html): the `compact_conversation` tool
- [`BeamWeaver.Agent.Middleware.OverflowRecovery`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.OverflowRecovery.html): retries after context overflow errors
- [`BeamWeaver.Agent.Middleware.PromptCaching`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.PromptCaching.html): provider prompt caching
- [`BeamWeaver.Compaction`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.html): compaction for transcripts your application stores
