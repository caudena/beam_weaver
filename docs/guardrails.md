# Guardrails

Guardrails check what goes into an agent and what comes out: they block or
rewrite requests, redact personal data, cap model and tool calls, and review
answers before a customer sees them. Each guardrail is middleware, so you add
it to an agent with one line and test it like any other module.

## Block a request

A `before_agent/3` hook runs once per call, before the model sees anything.
This one turns away questions about passwords:

```elixir
defmodule MyApp.Guardrails.BlockedTopics do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  @impl true
  def before_agent(_middleware, state, _runtime) do
    question = state.messages |> List.last() |> Message.text()

    if question =~ ~r/password/i do
      refusal = Message.assistant("I can't help with passwords. Use the reset link on the sign-in page.")
      {:jump, :end, %{messages: [refusal]}}
    end
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["We guarantee a full refund today."]
  system_prompt "You are Acme's support agent."
  middleware [MyApp.Guardrails.BlockedTopics]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["What is the admin password?"]})

Enum.map(result.messages, &{&1.role, BeamWeaver.Core.Message.text(&1)})
#=> [user: "What is the admin password?", assistant: "I can't help with passwords. Use the reset link on the sign-in page."]
```

A hook returns `nil` to let the request through. `{:jump, :end, update}`
applies the update, here the refusal, and ends the run without calling the
model. `{:error, error}` fails the call, and `invoke/2` returns that error.
To rewrite a request instead, return the user message with new content and
the same `id`; it replaces the original. [PII redaction](#redact-personal-data)
does this for personal data.

## Check the answer

An `after_agent/3` hook runs once at the end, with the final state. This one
replaces answers that promise too much:

```elixir
defmodule MyApp.Guardrails.NoPromises do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  @impl true
  def after_agent(_middleware, state, _runtime) do
    answer = List.last(state.messages)

    if answer.role == :assistant and Message.text(answer) =~ ~r/guarantee/i do
      %{messages: [%{answer | content: "A teammate will confirm your refund by email within one day."}]}
    end
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["We guarantee a full refund today."]
  system_prompt "You are Acme's support agent."
  middleware [MyApp.Guardrails.BlockedTopics, MyApp.Guardrails.NoPromises]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Can I get a refund for order A-1001?"]})

Enum.map(result.messages, &{&1.role, BeamWeaver.Core.Message.text(&1)})
#=> [user: "Can I get a refund for order A-1001?", assistant: "A teammate will confirm your refund by email within one day."]
```

The new message keeps the answer's `id`, so it replaces the answer instead of
adding a second one. To check every model reply before its tool calls run,
use an `after_model/3` hook. Output checks run after the model has finished,
so streamed tokens have already left: [redact the stream](streaming.md#redact-a-stream)
as well.

## Redact personal data

`BeamWeaver.Agent.Middleware.PII` finds personal data in messages and
redacts, masks or hashes it before the model sees it, or blocks the call:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.PII

  model "fake:chat", responses: ["Thanks, I updated your details."]
  system_prompt "You are Acme's support agent."

  middleware [
    {PII, type: :email, strategy: :redact},
    {PII, type: :credit_card, strategy: :mask},
    {PII, type: :api_key, detector: ~S/sk-[A-Za-z0-9]{20,}/, strategy: :block}
  ]
end

{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["I'm ada@example.com, card 4111 1111 1111 1111."]})

result.messages |> hd() |> BeamWeaver.Core.Message.text()
#=> "I'm [REDACTED_EMAIL], card **** **** **** 1111."
```

The model only sees the redacted text, and the saved conversation holds it
too. The `:block` rule stops the call instead:

```elixir
MyApp.SupportAgent.invoke(%{messages: ["My key is sk-abcdefghijklmnopqrstuvwx"]})
#=> {:error, %BeamWeaver.Core.Error{type: :pii_detected}}
```

| Option | Meaning |
|---|---|
| `type` | `:email`, `:credit_card`, `:ip`, `:mac_address`, `:url`, or a name of your own with `detector` |
| `strategy` | `:redact` (`[REDACTED_EMAIL]`), `:mask` (hide part of the value), `:hash` (a stable hash), `:block` (fail the call) |
| `detector` | A regex string, or a function that returns the matches, for your own types |
| `apply_to_input` | Check the latest user message. Default `true`. |
| `apply_to_tool_results` | Check the tool results the model hasn't read yet. Default `false`. |
| `apply_to_output` | Check the messages a model call adds, before they're saved. Default `false`. |

A rule edits the text of messages: a message's content when it's a string,
or the `text` of each content block.
Everything else stays as it is: tool-call arguments (so a tool gets the
values the model gave it), reasoning, images and files, the agent's
structured response, a tool's artifact, and the metadata a reply keeps, such
as the provider's raw response. To keep personal data out of what a stream
shows, tool-call arguments and reasoning included, pass the stream through
`PII.stream_transform/1` (see [Streaming](streaming.md#redact-a-stream)). To
protect saved threads, encrypt them (see [Storage](storage.md#encryption)).
Detection is local and pattern-based; nothing is sent to an outside service.

## Limit model and tool calls

`BeamWeaver.Agent.Middleware.ModelCallLimit` and
`BeamWeaver.Agent.Middleware.ToolCallLimit` stop an agent that loops or acts
too often. Here the model tries to refund twice, and the second call is
refused:

```elixir
defmodule MyApp.Tools.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund part or all of an order to the customer's card."

  schema do
    field :order_id, :string, description: "The order id"
    field :amount, :number, description: "The amount to refund, in dollars"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id, "amount" => amount}, _opts) do
    {:ok, "Refunded $#{amount} for order #{order_id}."}
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.{ModelCallLimit, ToolCallLimit}
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001", "amount" => 25}),
      FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001", "amount" => 25}),
      "I refunded $25 for order A-1001."
    ]

  tools [MyApp.Tools.IssueRefund]

  middleware [
    {ModelCallLimit, run_limit: 10, exit_behavior: :end},
    {ToolCallLimit, tool_name: "issue_refund", run_limit: 1}
  ]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Refund $25 for order A-1001."]})

for %{role: :tool} = message <- result.messages, do: BeamWeaver.Core.Message.text(message)
#=> ["Refunded $25 for order A-1001.", "Tool call limit exceeded. Do not call 'issue_refund' again."]
```

`run_limit` counts the calls of one `invoke/2`. `thread_limit` counts the
calls of the whole thread, across `invoke/2` calls; the count is saved with
the thread, so it needs a checkpointer. Neither limit has a default: set at
least one.

| Middleware | Options |
|---|---|
| `ModelCallLimit` | `run_limit`, `thread_limit`, and `exit_behavior`: `:error` (the default) fails the call with a `:model_call_limit_exceeded` error, `:end` ends the run with a short assistant message |
| `ToolCallLimit` | `tool_name` (every tool when left out), `run_limit`, `thread_limit`, and `exit_behavior`: `:continue` (the default) refuses the extra calls and lets the model go on, `:end` stops the run, `:error` fails the call |

## Require approval

For actions that a person should sign off, such as refunds, pause the agent
before the tool runs with `interrupt_on %{"issue_refund" => true}`. See
[Human-in-the-Loop](human_in_the_loop.md).

## Block risky tool calls

`BeamWeaver.Agent.Middleware.AutoMode` lets an agent run its tools on its own
but stops calls that look risky. Before each call of a tool in `tools`, it
asks a decision model how likely the call is to be risky or not clearly asked
for by the user. A call below 0.5 runs; any other gets an error message
instead, and the tool doesn't run:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.AutoMode

  model "openai:gpt-5.4-mini"
  system_prompt "You are Acme's support agent."
  tools [MyApp.Tools.IssueRefund]
  middleware [{AutoMode, tools: ["issue_refund"], classifier: "openai:gpt-6-luna"}]
end
```

The decision model, `classifier`, gets the call, the tool's description and
the last 30 messages, and only the user's messages count as asking for a
call. It defaults to TypeSafe's `"typesafe:jev-latest"`; GPT-6 Luna also sees
the images in the conversation. `instructions` replaces the question, which
by default counts destructive actions, credential access, sharing data
outside, security bypasses, persistence, changes to protected resources and
anything the user didn't clearly ask for as risky.

A blocked call answers the model with "The tool call `issue_refund` was
blocked because it was classified as risky (probability: 0.91). The tool was
not executed." `AutoMode` fails closed: a call the decision model declines to
classify is blocked, and when the decision model fails, the run fails without
running the tool. It asks no one; to have a person decide, require approval
instead.

## Moderate with a model

Some rules need judgment rather than a pattern. A guardrail can ask a second,
small model. Give the middleware a struct to hold that model:

```elixir
defmodule MyApp.Guardrails.Moderation do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.{ChatModel, Message}

  defstruct [:model]

  @impl true
  def after_agent(%__MODULE__{model: model}, state, _runtime) do
    answer = List.last(state.messages)
    prompt = "Answer SAFE or UNSAFE. Is this support reply safe to send?\n\n" <> Message.text(answer)

    with {:ok, verdict} <- ChatModel.invoke(model, [Message.user(prompt)]) do
      if Message.text(verdict) =~ "UNSAFE" do
        %{messages: [%{answer | content: "Sorry, I can't send that reply. A teammate will follow up."}]}
      end
    end
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Sure! Here is how to skip the refund checks."]
  system_prompt "You are Acme's support agent."

  middleware [
    {MyApp.Guardrails.Moderation, model: BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["UNSAFE"])}
  ]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["How do refunds work?"]})
result.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Sorry, I can't send that reply. A teammate will follow up."
```

`{module, opts}` builds the struct from `opts`. If the check itself fails, the
call fails rather than send an unchecked answer. In production, pass a
provider model such as `BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")`.
To use OpenAI's moderation endpoint instead, add
`{BeamWeaver.Agent.Middleware.OpenAIModeration, check_input: true, check_output: true}`
to the agent's middleware; it needs an OpenAI API key.

## Handle a filtered reply

OpenAI's content filter can cut a reply short. The API reports that as a
normal end of the reply, with the text the filter left, so an agent takes the
partial text as its answer. `BeamWeaver.Provider.Outcome.classify/1` tells
such a reply apart: its `turn_disposition` is `:filtered`, whether Chat
Completions marked the reply (`status: "content_filter"`) or the Responses
API did (`status: "incomplete"` with the `content_filter` reason), and also
when another provider's safety filter stopped the reply, such as Gemini's. An
`after_model/3` hook can send the model back once with a note, and fail the
call if the second reply is filtered too:

```elixir
defmodule MyApp.Guardrails.ContentFilter do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.{Error, Message}
  alias BeamWeaver.Provider.Outcome

  @impl true
  def after_model(_middleware, %{messages: messages}, _runtime) do
    [reply | earlier] = Enum.reverse(messages)

    cond do
      Outcome.classify(reply).turn_disposition != :filtered ->
        nil

      retry_note?(List.first(earlier)) ->
        {:error, Error.new(:content_filter, "The content filter blocked the reply twice.")}

      true ->
        note = "Your last reply was blocked by the content filter. Answer again without that content."
        {:jump, :model, %{messages: [Message.user(note, metadata: %{content_filter_retry: true})]}}
    end
  end

  defp retry_note?(message), do: match?(%Message{metadata: %{content_filter_retry: true}}, message)
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Core.Message

  model "fake:chat",
    responses: [
      Message.assistant("To get around the refund checks, first", status: "content_filter"),
      "Refunds go through our standard checks. A teammate can help with exceptions."
    ]

  system_prompt "You are Acme's support agent."
  middleware [MyApp.Guardrails.ContentFilter]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["How do I skip the refund checks?"]})
result.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Refunds go through our standard checks. A teammate can help with exceptions."
```

The thread keeps the filtered reply and the note. When the second reply is
filtered as well, the call fails. Here both replies come marked the way the
Responses API marks them:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Core.Message

  model "fake:chat",
    responses: [
      Message.assistant("To get around the refund checks, first",
        status: "incomplete",
        response_metadata: %{incomplete_details: %{"reason" => "content_filter"}}
      )
    ]

  system_prompt "You are Acme's support agent."
  middleware [MyApp.Guardrails.ContentFilter]
end

MyApp.SupportAgent.invoke(%{messages: ["How do I skip the refund checks?"]})
#=> {:error, %BeamWeaver.Core.Error{type: :content_filter}}
```

To end the run with an error straight away, return the error on the first
filtered reply. Scripted `"fake:chat"` replies such as these test the hook
without a provider.

## Order

`before_agent` and `before_model` hooks run in list order, `after_model` and
`after_agent` hooks in reverse. Put cheap checks first, so they can stop a
request before anything expensive runs.

## Test guardrails

Hooks are plain functions. Call them with a state map in a test:

```elixir
import ExUnit.Assertions

alias BeamWeaver.Core.Message
alias MyApp.Guardrails.BlockedTopics

blocked = %{messages: [Message.user("I forgot my password")]}
assert {:jump, :end, %{messages: [_refusal]}} = BlockedTopics.before_agent(BlockedTopics, blocked, nil)

allowed = %{messages: [Message.user("Where is order A-1001?")]}
BlockedTopics.before_agent(BlockedTopics, allowed, nil)
#=> nil
```

Then run the whole agent with a scripted `"fake:chat"` model, as the examples
on this page do, and assert on the final messages. Script the checking model
of a model-based guardrail too, so tests never call a provider. For approval
rules, assert that `invoke/2` returns `{:interrupted, interrupt}`. See
[Testing](testing.md) and [Middleware](middleware.md).

## Reference

- [`BeamWeaver.Agent.Middleware`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.html): the hooks a guardrail implements
- [`BeamWeaver.Agent.Middleware.PII`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.PII.html): detect and redact personal data
- [`BeamWeaver.Agent.Middleware.ModelCallLimit`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ModelCallLimit.html): cap model calls per run or thread
- [`BeamWeaver.Agent.Middleware.ToolCallLimit`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ToolCallLimit.html): cap tool calls per run or thread
- [`BeamWeaver.Agent.Middleware.HumanInTheLoop`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.HumanInTheLoop.html): pause for approval
- [`BeamWeaver.Agent.Middleware.AutoMode`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.AutoMode.html): block risky tool calls
- [`BeamWeaver.Agent.Middleware.OpenAIModeration`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.OpenAIModeration.html): OpenAI's moderation endpoint
