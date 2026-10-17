# Built-in Middleware

BeamWeaver ships middleware for common needs: retries and fallbacks, call
limits, choosing tools, prompts, personal data, and keeping the context small.
Add them to an agent's `middleware` list like your own
([Middleware](middleware.md)).

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware

  model "fake:chat", responses: ["Thanks! I'll send the details to that address."]

  middleware [
    {Middleware.ModelRetry, max_retries: 2, initial_delay: 500},
    {Middleware.ModelCallLimit, run_limit: 10},
    {Middleware.PII, type: :email, strategy: :redact}
  ]
end

alias BeamWeaver.Core.Message

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Email me at ada@example.com"]})
Enum.map(result.messages, &Message.text/1)
#=> ["Email me at [REDACTED_EMAIL]", "Thanks! I'll send the details to that address."]
```

All modules live under `BeamWeaver.Agent.Middleware`, and each entry takes
its options as `{Module, options}`.

| Need | Middleware |
| --- | --- |
| Retry a failing model or tool | [`ModelRetry`](#modelretry), [`ToolRetry`](#toolretry) |
| Switch to another model when one fails | [`ModelFallback`](#modelfallback) |
| Cap model or tool calls | [`ModelCallLimit`](#modelcalllimit), [`ToolCallLimit`](#toolcalllimit) |
| Control which tools the model sees or must call | [`ToolSelection`](#toolselection), [`ToolChoice`](#toolchoice) |
| Repair malformed tool calls | [`ToolCallNormalization`](#toolcallnormalization) |
| Build the system prompt per call | [`DynamicPrompt`](#dynamicprompt) |
| Retry invalid structured output | [`StructuredOutputRetry`](#structuredoutputretry) |
| Redact emails, card numbers and more | [`PII`](#pii) |
| Keep long conversations small | [`ContextEditing`](#contextediting), [`Summarization`](#summarization) |

## Retries and fallbacks

### ModelRetry

Retries a model call that fails with a temporary error, such as a rate limit
or a timeout:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware

  model "fake:chat", error: BeamWeaver.Core.Error.new(:rate_limit, "Too many requests")

  middleware [{Middleware.ModelRetry, max_retries: 2, initial_delay: 10, on_failure: :continue}]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
result.messages |> List.last() |> Message.text()
#=> "Model call failed after 3 attempts with rate_limit: Too many requests"
```

The scripted model fails every time, so all three attempts fail. By default
the run then returns the error; `on_failure: :continue` ends it with an
assistant message instead, and with a one-argument function you write that
message from the error yourself. `on_failure` handles only the retries
running out: an error `retry_on` doesn't cover, such as a bad API key, is
returned as it is, so a `ModelFallback` listed before `ModelRetry` still
gets it.

| Option | Default | Meaning |
| --- | --- | --- |
| `max_retries` | `2` | retries after the first attempt |
| `initial_delay` | `0` | milliseconds before the first retry; set it for real providers |
| `backoff` | `2.0` | multiplies the delay after each retry |
| `max_delay` | `5_000` | upper bound of the delay, in milliseconds |
| `jitter` | `false` | `true` adds a random part to each delay |
| `retry_on` | `:transient` | which errors to retry: `:transient`, `:error` (all but those marked `retryable: false`), an error type or a list of types, or a function of the error |
| `on_failure` | `:error` | `:error`, `:continue`, or a function that returns the final message |

`:transient` covers the errors [marked retryable](models.md#errors), such as
timeouts, rate limits and server errors, so an invalid API key fails at once
instead of being retried. A
streamed reply that the provider breaks off with an error, such as Anthropic's
`overloaded_error`, counts as the same error without streaming: an overload is
retried, a content filter or an exhausted quota is not. A reply that Z.ai or
DeepSeek ends with a finish reason that reports a failure fails too, with or
without streaming (see [Models](models.md#stream-a-reply)): Z.ai's content
filter (`sensitive`) is not retried, the others are. In a stream
(`stream_events/2`), each failed attempt sends a `Debug` event with
`type: :model_call_failed` instead of an `Error` event; see
[Streaming](streaming.md#errors).

### ModelFallback

Tries other models, in order, when the agent's model returns an error:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware

  model "fake:chat", error: BeamWeaver.Core.Error.new(:provider_error, "Service unavailable")

  middleware [
    {Middleware.ModelFallback,
     fallbacks: [BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Your order shipped on Monday."])]}
  ]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
result.messages |> List.last() |> Message.text()
#=> "Your order shipped on Monday."
```

`fallbacks` takes `"provider:model"` strings, resolved the way the agent's
`model` is, or model values from `BeamWeaver.Models.init_chat_model!/2`, as
here, when a model needs options. A fallback uses its own API key and
connection settings, never those of the agent's model, and gets only the
agent's model options it takes, such as `temperature:`; `top_k:` for a
Claude model doesn't reach an OpenAI fallback. `retry_on` limits the
errors that switch models (default: all). To retry each model before moving to the next, list
`ModelFallback` before `ModelRetry`:

```elixir
model "anthropic:claude-sonnet-4-6"

middleware [
  {BeamWeaver.Agent.Middleware.ModelFallback, fallbacks: ["openai:gpt-5.4-mini"]},
  {BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 2, initial_delay: 500}
]
```

### ToolRetry

Retries tool calls that return an error. Here the service for old orders is
down, so every attempt fails and the model gets a message it can pass on:

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  alias BeamWeaver.Core.Error

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => "A-" <> _ = order_id}, _opts),
    do: {:ok, "Order #{order_id} shipped on Monday."}

  def invoke(_tool, _args, _opts),
    do: {:error, Error.new(:timeout, "The archive service timed out")}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "Z-0042"}),
      "I can't reach our order archive right now. Please try again in a few minutes."
    ]

  tools [MyApp.Tools.LookupOrder]
  middleware [{Middleware.ToolRetry, tools: ["lookup_order"], retry_on: :timeout, on_failure: :continue}]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my old order Z-0042?"]})
result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "Tool 'lookup_order' failed after 3 attempts with timeout: The archive service timed out. Please try again."
```

`ToolRetry` takes the options of `ModelRetry`, plus `tools` to retry only the
named tools. Its `retry_on` default is `:error`: every error except one that
says retrying can't help, such as an invalid API key from a model the tool
calls. With the default
`on_failure: :error`, the last failure reaches the model like any other tool
error (`"Tool error: ..."`), and so does an error `retry_on` doesn't cover,
whatever `on_failure` says.

### ToolError

Decides what the model reads when a tool fails, or stops the run instead.
`on_error` takes the error and the `BeamWeaver.Agent.ToolCallRequest`, and
returns the text the model reads, or `nil` to stop the run with the error.
Here it keeps the archive's error out of the conversation:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "Z-0042"}),
      "Our order archive is down. Please try again in a few minutes."
    ]

  tools [MyApp.Tools.LookupOrder]
  middleware [{Middleware.ToolError, on_error: &__MODULE__.on_error/2}]

  def on_error(%BeamWeaver.Core.Error{type: :timeout}, request),
    do: "#{request.tool_call.name} is unavailable right now. Ask the customer to try again later."

  def on_error(_error, _request), do: nil
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my old order Z-0042?"]})
result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "lookup_order is unavailable right now. Ask the customer to try again later."
```

`tools` limits it to the named tools. Arguments the model got wrong, and calls
to a tool the agent doesn't have, still reach the model as they are, so it can
fix the call. `ToolError` doesn't retry: list `ToolRetry` after it, and the
last failure reaches `on_error`.

## Limits

### ModelCallLimit

Caps model calls to stop runaway loops and costs. `run_limit` counts the
calls of one `invoke/2`; `thread_limit` counts every call on a thread, across
`invoke/2` calls. Neither has a default, so set the ones you need:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Models.FakeChatModel

  # This script repeats its tool call forever.
  model "fake:chat", responses: [FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"})]

  tools [MyApp.Tools.LookupOrder]
  middleware [{Middleware.ModelCallLimit, run_limit: 3, exit_behavior: :end}]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
result.messages |> List.last() |> Message.text()
#=> "Model call limits exceeded: run limit (3/3)"
```

With the default `exit_behavior: :error`, the run returns
`{:error, %BeamWeaver.Core.Error{type: :model_call_limit_exceeded}}` instead.
`message` replaces the text of the final message.

The thread count is saved with the thread's checkpoints, so `thread_limit`
needs a checkpointer; without one, every `invoke/2` starts a new thread. Here
the second question on the thread is the third model call:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware

  model "fake:chat", responses: ["It shipped on Monday.", "It arrives on Thursday."]
  middleware [{Middleware.ModelCallLimit, thread_limit: 2, exit_behavior: :end}]
end

opts = [checkpointer: BeamWeaver.Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => "ticket-7"}}]

{:ok, _first} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]}, opts)
{:ok, _second} = MyApp.SupportAgent.invoke(%{messages: ["When will it arrive?"]}, opts)
{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Can I change the address?"]}, opts)
result.messages |> List.last() |> Message.text()
#=> "Model call limits exceeded: thread limit (2/2)"
```

### ToolCallLimit

Caps tool calls, for every tool or for one `tool_name`, with the same
`run_limit` and `thread_limit`. A blocked call gets a tool message that tells
the model to stop, and the run goes on:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1002"}),
      "A-1001 shipped on Monday. Ask me about A-1002 in a new message."
    ]

  tools [MyApp.Tools.LookupOrder]
  middleware [{Middleware.ToolCallLimit, tool_name: "lookup_order", run_limit: 1}]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where are A-1001 and A-1002?"]})
result.messages |> Enum.filter(&(&1.role == :tool)) |> Enum.map(&Message.text/1)
#=> ["Order A-1001 shipped on Monday.", "Tool call limit exceeded. Do not call 'lookup_order' again."]
```

`exit_behavior: :end` ends the run at the limit, and `:error` fails it.
`message` replaces the text of the blocked call's tool message. When you set
both limits, `run_limit` can't exceed `thread_limit`. Add one `ToolCallLimit`
per tool you want to cap.

## Tools

### ToolSelection

Filters the tools the model sees on each call. A tool that is filtered out is
also refused if the model calls it anyway:

```elixir
defmodule MyApp.Tools.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund an order."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Refunded #{order_id}."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001"}),
      "I can't issue refunds, but I can hand you to our billing team."
    ]

  tools [MyApp.Tools.LookupOrder, MyApp.Tools.IssueRefund]
  middleware [{Middleware.ToolSelection, deny: ["issue_refund"]}]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Refund A-1001!"]})
result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "Tool error: tool is not registered" <> _
```

| Option | Keeps or adds |
| --- | --- |
| `allow`, `deny` | only the listed tool names; or all but them |
| `tags`, `metadata` | tools with a matching `tags` entry or `metadata` values |
| `predicate` | tools for which `fn tool, request -> boolean end` is true |
| `tools` | extra tools for this call: a list, or a function of the request |
| `descriptions` | a map of tool name to a new description |

A run that pauses before its tools run, such as for a review with
`interrupt_on`, keeps only the names of the tools the model was offered, so
after `resume` the model's calls run with the same tools: a tool filtered out
is still refused. Tools from a function under `tools` are made again on the
next model call only, so after `resume` a call to one gets "tool is not
registered"; list them to keep them across a pause.

With `model`, a model picks the relevant tools from the user's last message,
up to `max_tools`; `always_include` names tools it can't drop. A reply
without a list of tools is asked for again `max_retries` times (default 1);
then `on_parsing_failure` decides: `:error` (the default) fails the call,
`:none` offers no tools, `:all` every tool, and a list of names or a function
of the reply those tools, which `max_tools` doesn't cap. Use a small, fast
model for this:

```elixir
model "anthropic:claude-sonnet-4-6"
tools [MyApp.Tools.LookupOrder, MyApp.Tools.IssueRefund]

middleware [
  {BeamWeaver.Agent.Middleware.ToolSelection,
   model: "openai:gpt-5.4-mini", max_tools: 3, always_include: ["lookup_order"]}
]
```

The declarations `exclude_tools` and `tool_descriptions` add a
`ToolSelection` with `deny` and `descriptions` for you. It runs before a
`ToolSelection` of your own, so both apply: yours chooses from the tools that
are left, with their new descriptions.

### ToolChoice

Tells the provider whether the next model call must use a tool. `choice` is
`:auto`, `:required` or `:none` (Anthropic and Google also take a tool name),
or a function of the request that returns one. This one makes the model call
a tool on the first call only; forcing it on every call would never let the
model answer:

```elixir
alias BeamWeaver.Agent.Middleware.ToolChoice
alias BeamWeaver.Agent.ModelRequest

choice =
  ToolChoice.new(choice: fn request ->
    if length(request.messages) == 1, do: :required, else: :auto
  end)

first_call = ModelRequest.new(messages: [Message.user("Where is my order A-1001?")])
ToolChoice.wrap_model_call(choice, first_call, & &1.tool_choice)
#=> :required
```

In an agent: `middleware [{ToolChoice, choice: ...}]`. `when_tool_present`
applies the choice only while the named tools are offered.

### ToolCallNormalization

Repairs tool calls from providers before tools run: it fills in or cleans up
call ids, decodes arguments sent as a JSON string, and cuts arguments longer
than `max_argument_chars` (default 20,000). Every agent with tools or
middleware already runs it, so add it yourself only to change the limit:

```elixir
alias BeamWeaver.Agent.Middleware.ToolCallNormalization
alias BeamWeaver.Agent.ModelResponse

call = %{id: "call 1", name: "add_note", args: ~s({"note": "#{String.duplicate("x", 30)}"})}
response = %ModelResponse{messages: [Message.assistant("", tool_calls: [call])]}
normalization = ToolCallNormalization.new(max_argument_chars: 10)

{:ok, %{messages: [message]}} =
  ToolCallNormalization.wrap_model_call(normalization, ModelRequest.new(), fn _ -> {:ok, response} end)

[call] = message.tool_calls
{call.id, call.args}
#=> {"call_1", %{"note" => "xxxxxxxxxx\n\n... argument truncated at 10 bytes."}}
```

## Prompts and output

### DynamicPrompt

Replaces the system prompt on every model call with the result of `prompt`:
a string, a function of the request, a function of `state` and `runtime`, or
an `{module, function, args}` tuple. It replaces the agent's
`system_prompt`, so include the parts of it you want to keep. It runs before
the other middleware, so the sections that `filesystem`, `memory`, `skills`,
`subagents` and middleware such as `TodoList` add to the prompt come after
yours:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.DynamicPrompt

  model "fake:chat", responses: ["Hello Ada! How can I help?"], parent: self()
  filesystem BeamWeaver.Filesystem.State.new()
  middleware [{DynamicPrompt, prompt: &__MODULE__.prompt/2}]

  def prompt(_state, runtime) do
    "You are Acme's support agent. The customer's name is #{runtime.context.customer_name}."
  end
end

{:ok, _result} = MyApp.SupportAgent.invoke(%{messages: ["Hi!"]}, context: %{customer_name: "Ada"})

prompt =
  receive do
    {:fake_chat_model_call, [system_message, _question], _opts} -> Message.text(system_message)
  end

{String.starts_with?(prompt, "You are Acme's support agent. The customer's name is Ada."), prompt =~ "## Filesystem Tools"}
#=> {true, true}
```

Declare the context the prompt reads with `context_schema`, so a missing key
fails with a clear error ([Runtime Context](runtime_context.md)).

### StructuredOutputRetry

When an agent has a response schema and the model's answer doesn't parse or
validate, this middleware adds the answer and the error to the conversation
and asks again, up to `max_retries` times (default 1). Here the first answer
leaves out `urgent`:

```elixir
defmodule MyApp.Schemas.Triage do
  use BeamWeaver.Schema

  field :category, :string, enum: ["billing", "shipping", "returns"]
  field :urgent, :boolean
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.final(%{category: "shipping"}),
      FakeChatModel.final(%{category: "shipping", urgent: true})
    ]

  response_schema MyApp.Schemas.Triage

  middleware [
    {BeamWeaver.Agent.Middleware.StructuredOutputRetry,
     max_retries: 2, feedback: "Your answer didn't match the schema: {error}. Answer again."}
  ]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["My parcel never arrived!"]})
result.structured_response
#=> %{"category" => "shipping", "urgent" => true}
```

`feedback` is a template with `{error}`, or a function of the error. When the
retries run out, `invoke/2` returns the last error. The tool strategy already
sends a failing answer back to the model on its own, so this middleware is for
native output, or for the tool strategy with `handle_errors: false`. See
[Structured Output](structured_output.md#validation-errors-and-retries).

### PII

Finds personal data in messages and redacts, masks, hashes or blocks it.
Built-in types are `:email`, `:credit_card`, `:ip`, `:mac_address` and `:url`.
Without `type`, one middleware checks them all; add one per type when types
need different strategies:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware

  model "fake:chat", responses: ["Thanks, I've noted your card."]

  middleware [
    {Middleware.PII, type: :credit_card, strategy: :mask},
    {Middleware.PII, type: :url, strategy: :block, apply_to_input: false, apply_to_output: true}
  ]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["My card is 4111 1111 1111 1111"]})
result.messages |> hd() |> Message.text()
#=> "My card is **** **** **** 1111"
```

| Option | Default | Meaning |
| --- | --- | --- |
| `type` | (all built-in types) | the kind of data to look for |
| `strategy` | `:redact` | `:redact` (`[REDACTED_EMAIL]`), `:mask` (keeps a little, such as a card's last 4 digits or an email's user name), `:hash`, or `:block` (fails the run) |
| `apply_to_input` | `true` | check the user's latest message before the model call |
| `apply_to_tool_results` | `false` | check the tool results the model hasn't read yet |
| `apply_to_output` | `false` | check the messages a model call adds, before they're saved |
| `detector` | | your own regex string or function, for a custom `type` |

`:block` returns `{:error, %BeamWeaver.Core.Error{type: :pii_detected}}`.
The edited message replaces the original in the agent's state, so the model
never reads the raw value. A rule edits message text only (string content,
or the `text` of each content block) of the user's message, the tool results
or the model's reply, including the structured answer of an agent with tools
and the failed answers that `StructuredOutputRetry` keeps. Tool-call
arguments, reasoning, metadata and the structured response stay as they are;
see [Guardrails](guardrails.md#redact-personal-data).

## Context size

### ContextEditing

Clears old tool results from what the model reads once the conversation is
over `trigger` tokens, keeping the latest `keep` results. The saved state
keeps the full results; only the model call sees the edit:

```elixir
model "anthropic:claude-sonnet-4-6"
middleware [{BeamWeaver.Agent.Middleware.ContextEditing, trigger: 50_000, keep: 3}]
```

`ContextEditing.clear_tool_uses/2` applies the same edit to a list of
messages:

```elixir
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

Other options: `exclude_tools` (never clear these), `clear_tool_inputs: true`
(also clear the call arguments) and `placeholder`. Tokens are counted
approximately; `token_count_method: :model` counts them with the agent's
model, and `token_counter`, a function of a message list that returns its
token count, counts them your way, such as with a provider's tokenizer.

### Summarization

Replaces older messages with a summary once a `trigger` is reached, keeping
the latest messages as they are. The summary comes from its own model:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware

  model "fake:chat", responses: ["Anything else I can help with?"]

  middleware [
    {Middleware.Summarization,
     model: BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Ada asked about A-1001; it shipped Monday."]),
     trigger: {:messages, 4},
     keep: {:messages, 1}}
  ]
end

{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["Hi, I'm Ada.", "Where is A-1001?", "Thanks!", "One more question."]})

Enum.map(result.messages, &Message.text/1)
#=> ["Conversation summary:\nAda asked about A-1001; it shipped Monday.", "One more question.", "Anything else I can help with?"]
```

`trigger` is `{:messages, n}` (default 20), `{:tokens, n}`, or
`{:fraction, f}` of `max_input_tokens`, the context window of the agent's
model, which you set along with a fraction; a list of triggers fires on any
of them, and `{:all, triggers}` on all. `keep` (default `{:messages, 8}`) is
a single `{:messages, n}`, `{:tokens, n}` or `{:fraction, f}`. Unlike
`ContextEditing`, the summary replaces the history in the saved state. A
`summarizer:` function of the old messages can write the summary instead of
a model. A failed summary call is retried unless retrying can't help; when it
still fails, the run returns the error and keeps the history. See
[Context Management](context_management.md#summarize-old-messages), which
also covers choosing between them.

## Documented elsewhere

| Middleware | Switched on by | Guide |
| --- | --- | --- |
| `HumanInTheLoop` | `interrupt_on` | [Human-in-the-Loop](human_in_the_loop.md) |
| `TodoList` | listing it in `middleware` | [Deep Agents](deep_agents.md) |
| `Filesystem` | `filesystem` | [Filesystem](filesystem.md) |
| `Skills` | `skills` | [Skills](skills.md) |
| `Memory` | `memory` | [Memory Files](memory_files.md) |
| `Subagents`, `AsyncSubagents` | `subagents`, `async_subagents` | [Subagents](subagents.md) |
| `SubagentOutputs` | listing it in `middleware`, for your own subagent tools | [Subagents](subagents.md) |
| `ShellTool` | listing it in `middleware` with a `policy:`, which it requires | [Sandboxes](sandboxes.md) |
| `ToolEmulator` | listing it in `middleware` | [Testing](testing.md#emulate-tools-with-side-effects) |
| `PromptCaching` | `prompt_caching` | [Caching](caching.md) |
| `OverflowRecovery`, `CompactConversation` | `overflow_recovery`, `compact_conversation` | [Context Management](context_management.md) |
| `AutoMode` | listing it in `middleware` | [Guardrails](guardrails.md#block-risky-tool-calls) |
| `TypeSafeModelRouter` | listing it in `middleware` | [TypeSafe](providers/typesafe.md#route-an-agent) |
| `BeamWeaver.OpenAI.ModerationMiddleware` | listing it in `middleware` | [Guardrails](guardrails.md) |

## Reference

- [`BeamWeaver.Agent.Middleware.ModelRetry`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ModelRetry.html): retry failed model calls
- [`BeamWeaver.Agent.Middleware.ModelFallback`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ModelFallback.html): fall back to other models
- [`BeamWeaver.Agent.Middleware.ToolRetry`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ToolRetry.html): retry failed tool calls
- [`BeamWeaver.Agent.Middleware.ModelCallLimit`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ModelCallLimit.html): cap model calls
- [`BeamWeaver.Agent.Middleware.ToolCallLimit`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ToolCallLimit.html): cap tool calls
- [`BeamWeaver.Agent.Middleware.ToolSelection`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ToolSelection.html): filter and select tools
- [`BeamWeaver.Agent.Middleware.ToolChoice`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ToolChoice.html): force or forbid tool use
- [`BeamWeaver.Agent.Middleware.ToolCallNormalization`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ToolCallNormalization.html): repair provider tool calls
- [`BeamWeaver.Agent.Middleware.DynamicPrompt`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.DynamicPrompt.html): per-call system prompts
- [`BeamWeaver.Agent.Middleware.StructuredOutputRetry`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.StructuredOutputRetry.html): retry invalid structured output
- [`BeamWeaver.Agent.Middleware.PII`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.PII.html): detect and edit personal data
- [`BeamWeaver.Agent.Middleware.ContextEditing`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ContextEditing.html): clear old tool results
- [`BeamWeaver.Agent.Middleware.Summarization`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Summarization.html): summarize old messages
- [`BeamWeaver.RetryPolicy`](https://hexdocs.pm/beam_weaver/BeamWeaver.RetryPolicy.html): the retry options shared by the retry middleware
