# Built-in Middleware

Choose policies for the failure and resource limits your application actually
needs. Add them through the [middleware DSL](middleware.md), then check their
ordering and total retry budget. All short module names below are under
`BeamWeaver.Agent.Middleware`.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Start with a bounded agent

After [Installation](installation.md), this makes a real OpenAI call with
bounded retries and a maximum of four model turns:

```elixir
defmodule MyApp.BoundedAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Answer briefly."
  run_timeout 120_000

  middleware do
    use BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 2, initial_delay: 500, max_delay: 5_000, jitter: true
    use BeamWeaver.Agent.Middleware.ModelCallLimit, run_limit: 4
  end
end

{:ok, result} = MyApp.BoundedAgent.invoke(%{messages: ["Explain parcel tracking in one sentence."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

This successful request exercises the configured agent; it does not simulate
an outage or exhaust the limits. [Testing](testing.md) shows how to verify
those branches deterministically without forcing provider failures.

## Retries and fallbacks

### ModelRetry

Retries transient provider failures. Defaults are two retries after the first
attempt, zero initial delay, backoff 2.0, a 5,000 ms maximum delay and no jitter.
Set a nonzero delay and jitter for a shared production service.

`retry_on:` accepts `:transient`, `:error`, error types or a predicate.
`:error` still respects explicit `retryable: false`. Authentication, invalid
requests and exhausted billing should be corrected rather than repeated.

`on_failure:` applies after covered retries are exhausted: `:error` returns
the error, `:continue` ends with an assistant message, and a function builds
that message. Errors outside the retry policy propagate unchanged. Failed
streaming attempts remain observable as debug events; see
[Streaming](streaming.md#errors).

### ModelFallback

`fallbacks:` lists model identifiers or constructed model values in order.
`retry_on:` controls which failures trigger fallback; the default covers all.
A fallback uses its own credentials/connection settings and only compatible
model options from the primary request.

Place fallback before retry to retry each candidate before moving on.
Confirm that each fallback supports your tools, media and answer schema.
Fallback changes the provider executing the task; it is not proof that the
primary provider recovered.

Configure a real primary and fallback in order. This successful call checks the configuration; the failure branch is exercised with a scripted provider in the application testing guide:

```elixir
defmodule MyApp.FallbackAgent do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000

  middleware [
    {BeamWeaver.Agent.Middleware.ModelFallback, fallbacks: ["google:gemini-3.5-flash"]},
    {BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 1, initial_delay: 500}
  ]
end

{:ok, result} = MyApp.FallbackAgent.invoke(%{messages: ["Say hello briefly."]})
true = byte_size(BeamWeaver.Core.Message.text(List.last(result.messages))) > 0
```

### ToolRetry

Takes the retry settings above plus `tools:` to restrict it to named actions.
Its default `retry_on: :error` covers tool errors except those explicitly
marked nonretryable. The final error normally returns to the model as a tool
message. Retry a mutating action only if it is idempotent or has a stable
application-level operation key.

This complete example makes the local lookup fail once, then succeed. A trusted per-run counter makes the transient failure reproducible while the model call is real:

```elixir
defmodule MyApp.UnstableLookup do
  use BeamWeaver.Tool
  name "lookup_order"
  description "Read the delivery day for order A-1001."
  injected :context, :context

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => "A-1001", context: %{counter: counter}}, _opts) do
    attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

    if attempt == 1,
      do: {:error, BeamWeaver.Core.Error.new(:timeout, "Temporary lookup failure")},
      else: {:ok, "A-1001 arrives Thursday."}
  end
end

defmodule MyApp.RetryingLookup do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Use lookup_order once, then report its result."
  tools [MyApp.UnstableLookup]

  middleware [
    {BeamWeaver.Agent.Middleware.ToolRetry, tools: ["lookup_order"], max_retries: 1, initial_delay: 10},
    {BeamWeaver.Agent.Middleware.ToolChoice,
     choice: fn request ->
       if Enum.any?(request.messages, &(&1.role == :tool)), do: :none, else: :required
     end}
  ]
end

{:ok, counter} = Agent.start_link(fn -> 0 end)

try do
  {:ok, result} = MyApp.RetryingLookup.invoke(%{messages: ["Look up A-1001."]}, context: %{counter: counter})
  2 = Agent.get(counter, & &1)
  true = Enum.any?(result.messages, &(&1.role == :tool and BeamWeaver.Core.Message.text(&1) =~ "Thursday"))
after
  Agent.stop(counter)
end
```

### ToolError

`on_error:` receives the error and tool-call request. Return text for the
model, or `nil` to fail the run. `tools:` scopes the rule. Invalid arguments
and calls to unavailable tools retain their corrective errors.
This middleware does not retry. With `ToolError` outside `ToolRetry`, it sees
the last failure after retries.

Convert the same failed lookup into application-specific feedback. This agent makes only one tool attempt:

```elixir
defmodule MyApp.ExplainedLookup do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Call lookup_order, then explain its result without retrying."
  tools [MyApp.UnstableLookup]

  middleware [
    {BeamWeaver.Agent.Middleware.ToolError,
     on_error: fn _error, _request -> "The order service is temporarily unavailable." end},
    {BeamWeaver.Agent.Middleware.ToolChoice,
     choice: fn request ->
       if Enum.any?(request.messages, &(&1.role == :tool)), do: :none, else: :required
     end}
  ]
end

{:ok, counter} = Agent.start_link(fn -> 0 end)

try do
  {:ok, result} = MyApp.ExplainedLookup.invoke(%{messages: ["Look up A-1001."]}, context: %{counter: counter})
  1 = Agent.get(counter, & &1)

  true =
    Enum.any?(result.messages, &(&1.role == :tool and BeamWeaver.Core.Message.text(&1) =~ "temporarily unavailable"))
after
  Agent.stop(counter)
end
```

## Limits

### ModelCallLimit

`run_limit:` bounds one invocation; `thread_limit:` spans saved calls on a
thread. Neither is configured by default. Thread limits need a reused
checkpointer. `exit_behavior: :error` returns `:model_call_limit_exceeded`;
`:end` returns an explanatory message, customizable with `message:`.

A model-turn limit is distinct from token limits, provider attempts inside
retry wrappers and graph supersteps. Use a whole-run timeout as well.

A thread budget survives separate invocations when the saver and thread are reused:

```elixir
defmodule MyApp.TwoTurnAgent do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
  middleware [{BeamWeaver.Agent.Middleware.ModelCallLimit, thread_limit: 2, exit_behavior: :end}]
end

opts = [checkpointer: BeamWeaver.Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => "two-turns"}}]
{:ok, _} = MyApp.TwoTurnAgent.invoke(%{messages: ["Say hello."]}, opts)
{:ok, _} = MyApp.TwoTurnAgent.invoke(%{messages: ["Say goodbye."]}, opts)
{:ok, limited} = MyApp.TwoTurnAgent.invoke(%{messages: ["One more turn."]}, opts)
true = BeamWeaver.Core.Message.text(List.last(limited.messages)) =~ "thread limit (2/2)"
```

### ToolCallLimit

Use `run_limit:` and/or `thread_limit:`, optionally for one `tool_name:`.
The run limit cannot exceed a supplied thread limit. The default
`exit_behavior: :continue` rejects excess actions and lets the model explain;
`:end` stops the loop and `:error` fails it. `message:` customizes feedback.
Use separate instances when individual tools need separate limits.

A zero budget demonstrates the rejection boundary without running the tool handler:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 256, timeout: 60_000],
    tools: [MyApp.UnstableLookup],
    middleware: [
      {BeamWeaver.Agent.Middleware.ToolCallLimit, tool_name: "lookup_order", run_limit: 0, exit_behavior: :error},
      {BeamWeaver.Agent.Middleware.ToolChoice, choice: :required}
    ]
  )

{:error, error} = BeamWeaver.Agent.invoke(agent, %{messages: ["Look up A-1001."]})
:tool_call_limit_exceeded = error.type
```

## Tools

### ToolSelection

Selection changes both model-visible tools and the execution registry.

| Option | Purpose |
| --- | --- |
| `allow:`, `deny:` | Named inclusion/exclusion |
| `tags:`, `metadata:` | Match tool attributes |
| `predicate:` | Decide from the tool and request |
| `tools:` | Add a list or request-derived tools |
| `descriptions:` | Override model-visible descriptions |
| `model:`, `max_tools:`, `always_include:` | Model-assisted selection |

Model-assisted selection makes an additional call. `max_retries:` defaults
to 1 for malformed selection output. `on_parsing_failure:` can fail (default),
select none/all, or use a supplied list/function. Deliberately choose whether
failure should broaden access.

A paused run retains selected tool names. Dynamically created tools from a
function are rebuilt on a later model call, not automatically on tool resume;
use stable tool entries for actions that must survive review. Agent
`exclude_tools` and `tool_descriptions` declarations install a selection policy
before your explicit one.

An allowlist can expose a read-only lookup while withholding unrelated actions. The selected tool must execute:

```elixir
read =
  BeamWeaver.Core.Tool.from_function!(
    name: "read_policy",
    description: "Read the refund policy.",
    input_schema: %{"type" => "object", "properties" => %{}},
    handler: fn _, _ -> {:ok, "Refunds take five business days."} end
  )

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 256, timeout: 60_000],
    tools: [read, MyApp.UnstableLookup],
    system_prompt: "Read the refund policy before answering.",
    middleware: [{BeamWeaver.Agent.Middleware.ToolSelection, allow: ["read_policy"]}]
  )

{:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["How long do refunds take?"]})
["read_policy"] = result.messages |> Enum.filter(&(&1.role == :tool)) |> Enum.map(& &1.name) |> Enum.uniq()
```

### ToolChoice

`choice:` sets `:auto`, `:required`, `:none`, or a provider-supported named
choice. It can be a function of the request. `when_tool_present:` restricts
application to matching offered tools. Requiring a tool forever prevents a
normal prose answer; apply the requirement only to the turn that needs it.

Choose a tool on the first turn and permit a final answer afterward. This direct call makes the resolved policy visible:

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Agent.Middleware.ToolChoice
alias BeamWeaver.Agent.ModelRequest

choice =
  ToolChoice.new(
    choice: fn request ->
      if length(request.messages) == 1, do: :required, else: :auto
    end
  )

first_call = ModelRequest.new(messages: [Message.user("Where is my order A-1001?")])
ToolChoice.wrap_model_call(choice, first_call, & &1.tool_choice)
#=> :required
```

### ToolCallNormalization

Agents with tools/middleware already normalize call IDs and JSON argument
strings. An explicit instance customizes `max_argument_chars:` (default
20,000). Normalization repairs representation, not semantics or authorization.

Normalize a provider-shaped call before a tool is looked up. This local example shows both ID repair and argument truncation:

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Agent.ModelRequest
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

`prompt:` is a string/system message, a function of the request, a function of
state and runtime, or an MFA tuple called with the request first. It replaces
the base system prompt before other capability prompt sections are added.
Validate required caller fields with `context_schema`.

Use validated context to construct the prompt on each call:

```elixir
defmodule MyApp.NamedGreeter do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000

  context_schema do
    field :customer_name, :string
  end

  middleware [
    {BeamWeaver.Agent.Middleware.DynamicPrompt,
     prompt: fn _state, runtime ->
       "Greet #{runtime.context.customer_name} by name, briefly."
     end}
  ]
end

{:ok, result} = MyApp.NamedGreeter.invoke(%{messages: ["Hello"]}, context: %{customer_name: "Ada"})
true = BeamWeaver.Core.Message.text(List.last(result.messages)) =~ "Ada"
```

### StructuredOutputRetry

Adds the invalid answer and feedback, then retries parsing/validation failures.
`max_retries:` defaults to 1; `feedback:` is text with `{error}` or an error
function. For the tool strategy, set `handle_errors: false` if this middleware
should own correction rather than the strategy's own retry loop.
See [Structured Output](structured_output.md#validation-errors-and-retries).

Configure schema correction and execute a real extraction. This input is valid; use the malformed-answer example in Testing to force a retry:

```elixir
defmodule MyApp.Schemas.Triage do
  use BeamWeaver.Schema

  field :category, :string, enum: ["billing", "shipping", "returns"]
  field :urgent, :boolean
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000

  response_schema MyApp.Schemas.Triage

  middleware [
    {BeamWeaver.Agent.Middleware.StructuredOutputRetry,
     max_retries: 2, feedback: "Your answer didn't match the schema: {error}. Answer again."}
  ]
end

{:ok, result} =
  MyApp.SupportAgent.invoke(%{
    messages: ["An urgent shipping issue: my parcel never arrived. Classify as shipping and urgent."]
  })

result.structured_response
#=> %{"category" => "shipping", "urgent" => true}
```

### PII

Detects email, credit-card, IP, MAC-address and URL text. `type:` chooses a
kind; omission checks all built-in kinds. A custom `detector:` is a regex
string or match function. Strategies are `:redact`, `:mask`, `:hash` and
`:block` (`:pii_detected`).

`apply_to_input:` defaults to true; `apply_to_tool_results:` and
`apply_to_output:` default to false. Message-text edits do not scrub tool-call
arguments, reasoning, artifacts, structured response maps or raw metadata.
`stream_transform/1` has a separate scope for emitted events.
[Guardrails](guardrails.md#redact-personal-data) explains those boundaries.

The saved input shows masking before the provider sees it. The number here is a synthetic example:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware

  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000

  middleware [
    {Middleware.PII, type: :credit_card, strategy: :mask},
    {Middleware.PII, type: :url, strategy: :block, apply_to_input: false, apply_to_output: true}
  ]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["My card is 4111 1111 1111 1111"]})
result.messages |> hd() |> BeamWeaver.Core.Message.text()
#=> "My card is **** **** **** 1111"
```

## Context size

### ContextEditing

After `trigger:` tokens, replace older tool results while keeping `keep:`
recent results. Saved state is unchanged. Options include `exclude_tools:`,
`clear_tool_inputs:`, `placeholder:`, `token_count_method:` and a custom
`token_counter:`. `clear_tool_uses/2` applies the transformation directly.

Transform a completed tool exchange locally to inspect exactly which result is hidden:

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

### Summarization

Replace old saved messages with a summary. `model:` or `summarizer:` creates
it; `trigger:` and `keep:` define the window. Message, token and fractional
limits are supported; fractional middleware limits require `max_input_tokens:`.
A list of triggers means any; `{:all, triggers}` means all. `on_overflow: false`
disables overflow-triggered recovery. [Context Management](context_management.md)
provides an example that actually triggers and checks a summary.

This deliberately small threshold triggers a real summary and verifies that the order fact remains available:

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

`summarize/2` applies the same `trigger:` and `keep:` to a message list
outside a run. It returns `{:ok, %{summary: message, kept: messages}}`,
`:unchanged` when the trigger isn't reached or nothing can be summarized, or
`{:error, error}`:

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Agent.Middleware.Summarization

summarization =
  Summarization.new(
    summarizer: fn old -> "The customer asked about #{length(old)} orders." end,
    trigger: {:messages, 4},
    keep: {:messages, 1}
  )

history = for id <- ["A-1001", "A-1002", "A-1003", "A-1004"], do: Message.user("Where is order #{id}?")
{:ok, %{summary: summary, kept: kept}} = Summarization.summarize(summarization, history)
Message.text(summary)
#=> "Conversation summary:\nThe customer asked about 3 orders."
Enum.map(kept, &Message.text/1)
#=> ["Where is order A-1004?"]
```

## Documented elsewhere

| Middleware | Application capability |
| --- | --- |
| `HumanInTheLoop` | [Human review](human_in_the_loop.md) |
| `TodoList`, `Filesystem` | [Planning](deep_agents.md) and [workspace tools](filesystem.md) |
| `Skills`, `Memory` | [Skills](skills.md) and [memory files](memory_files.md) |
| `Subagents`, `AsyncSubagents`, `SubagentOutputs` | [Delegation](subagents.md) |
| `ShellTool` | [Command policies and sandboxes](sandboxes.md) |
| `ToolEmulator` | [Testing side-effecting tools](testing.md#emulate-tools-with-side-effects) |
| `UnsupportedMedia` | [Model input adaptation](models.md#images-and-pdfs) |
| `PromptCaching` | [Provider caching](caching.md) |
| `OverflowRecovery`, `CompactConversation` | [Context management](context_management.md) |
| `AutoMode`, `OpenAIModeration` | [Guardrails](guardrails.md) |
| `TypeSafeModelRouter` | [Model routing](providers/typesafe.md#route-an-agent) |
