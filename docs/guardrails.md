# Guardrails

Guardrails validate, filter, or interrupt agent behavior at important execution
boundaries. Use them to protect private data, require human approval for
sensitive actions, enforce business rules, moderate content, and validate final
answers before they leave your application.

BeamWeaver implements guardrails through middleware. A guardrail can run before
the agent starts, before or after each model call, after the agent finishes, or
around individual model and tool calls.

{% hint style="info" %}
**BeamWeaver Shape**

LangChain's Python guardrails page uses `create_agent`, decorator-based
middleware, and `Command(resume=...)` for human review. BeamWeaver uses
`use BeamWeaver.Agent` or `BeamWeaver.Agent.build/1`, Elixir middleware modules
or structs, `BeamWeaver.Agent.resume/3`, and tagged `{:ok, ...}`,
`{:interrupted, ...}`, or `{:error, ...}` results.
{% endhint %}

## Guardrail Approaches

BeamWeaver supports both common guardrail styles:

| Style | Use for | Tradeoff |
| --- | --- | --- |
| Deterministic | Regex checks, keyword policies, allowlists, quotas, schema checks, PII detection. | Fast and predictable, but misses nuanced violations. |
| Model-based | Safety classification, semantic policy checks, final answer review, moderation APIs. | More flexible, but slower, costlier, and provider-dependent. |

Deterministic guardrails should be your default for explicit rules. Add
model-based checks where the policy needs semantic judgment.

## Built-In Guardrails

### PII Detection

`BeamWeaver.Agent.Middleware.PII` detects and handles personally identifiable
information in message text. It can inspect user input, model output, and tool
results.

```elixir
defmodule MyApp.SafeSupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.PII

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  tools [MyApp.CustomerServiceTool, MyApp.EmailTool]

  middleware [
    {PII, type: :email, strategy: :redact, apply_to_input: true},
    {PII, type: :credit_card, strategy: :mask, apply_to_input: true},
    {PII,
     type: :api_key,
     detector: ~S/sk-[A-Za-z0-9]{32}/,
     strategy: :block,
     apply_to_input: true}
  ]
end
```

Supported strategies:

| Strategy | Behavior |
| --- | --- |
| `:redact` | Replace with `[REDACTED_TYPE]`. |
| `:mask` | Keep only a safe suffix or type-specific masked shape. |
| `:hash` | Replace with a deterministic short hash marker. |
| `:block` | Return a tagged `:pii_detected` error from the middleware boundary. |

Built-in detector types are `:email`, `:credit_card`, `:ip`, `:mac_address`,
and `:url`. Custom detectors are supported as regex strings or functions that
return match maps with `:text` or `:value`, `:start`, and `:end` byte offsets.

```elixir
defmodule MyApp.PII do
  def detect_ssn(content) do
    Regex.scan(~r/\d{3}-\d{2}-\d{4}/, content, return: :index)
    |> Enum.map(fn [{start, length}] ->
      %{text: binary_part(content, start, length), start: start, end: start + length}
    end)
  end
end

middleware [
  {BeamWeaver.Agent.Middleware.PII,
   type: :ssn,
   detector: &MyApp.PII.detect_ssn/1,
   strategy: :hash}
]
```

{% hint style="warning" %}
**Local PII Detection**

BeamWeaver's PII middleware is local and pattern-based. It does not call a DLP
service or provider moderation endpoint. Use `BeamWeaver.OpenAI.ModerationMiddleware`
or a custom middleware backed by your approved service when compliance requires
external classification.
{% endhint %}

### Human-In-The-Loop

`BeamWeaver.Agent.Middleware.HumanInTheLoop` pauses before configured tool calls
and returns an interrupt payload for your UI, CLI, or service layer to review.
This is the preferred guardrail for high-impact operations such as sending
messages, writing production data, making purchases, or deleting records.

```elixir
defmodule MyApp.ReviewedAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.HumanInTheLoop

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")
  tools [MyApp.SearchTool, MyApp.SendEmailTool, MyApp.DeleteRecordTool]

  middleware [
    {HumanInTheLoop,
     interrupt_on: %{
       "send_email" => %{allowed_decisions: [:approve, :edit, :reject]},
       "delete_record" => true,
       "search" => false
     },
     tools: [MyApp.SearchTool, MyApp.SendEmailTool, MyApp.DeleteRecordTool]}
  ]
end
```

Human review requires a checkpointer because the graph must pause and resume
from a persisted state.

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "review-thread-1"}}

case MyApp.ReviewedAgent.invoke(
       %{messages: [Message.user("Send the launch update to the team.")]},
       checkpointer: checkpointer,
       config: config
     ) do
  {:interrupted, interrupt} ->
    IO.inspect(interrupt.value.action_requests)

    MyApp.ReviewedAgent.resume(
      %{decisions: [%{type: :approve}]},
      checkpointer: checkpointer,
      config: config
    )

  other ->
    other
end
```

Decision types are `:approve`, `:edit`, `:reject`, and `:respond`. Use
`BeamWeaver.Agent.resume_review/3` when you want BeamWeaver to normalize
decision structs or raw decision lists into the expected resume payload.

{% hint style="info" %}
**Resume Payloads Are Elixir Data**

Python examples resume with `Command(resume=...)`. BeamWeaver resumes with
`BeamWeaver.Agent.resume/3`, the generated module `resume(...)` helper, or
`BeamWeaver.Agent.resume_review/3`. The resume value is a map or list of
decision maps, not a LangGraph `Command` object.
{% endhint %}

### OpenAI Moderation

`BeamWeaver.OpenAI.ModerationMiddleware` is a provider-backed model-based
guardrail for OpenAI moderation. It can check input, output, and tool results.

```elixir
middleware [
  BeamWeaver.OpenAI.ModerationMiddleware.new(
    check_input: true,
    check_output: true,
    check_tool_results: false,
    exit_behavior: :end
  )
]
```

The `:exit_behavior` option controls what happens when content is flagged:

| Behavior | Result |
| --- | --- |
| `:end` | Jump to the end with a violation message. |
| `:replace` | Replace the flagged message content with a violation message. |
| `:error` | Return a tagged `:openai_moderation_violation` error. |

{% hint style="warning" %}
**Provider-Specific Scope**

LangChain documents provider middleware catalogs for several integrations.
BeamWeaver currently has OpenAI moderation middleware and provider-specific
adapter options documented in provider guides. AWS or Anthropic moderation
middleware is not part of BeamWeaver unless you add it as custom middleware.
{% endhint %}

## Custom Guardrails

Use custom middleware when the built-in guardrails do not encode your policy.
BeamWeaver does not expose Python decorators such as `@before_agent`; instead,
implement the `BeamWeaver.Agent.Middleware` behaviour.

### Before-Agent Guardrails

Use `before_agent` for request-level checks that should run once before any
model or tool work happens.

```elixir
defmodule MyApp.ContentFilterMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  defstruct banned_keywords: []

  def new(opts \\ []) do
    words =
      opts
      |> Keyword.get(:banned_keywords, [])
      |> Enum.map(&String.downcase/1)

    %__MODULE__{banned_keywords: words}
  end

  def name(_middleware), do: :content_filter

  def can_jump_to(_middleware, :before_agent), do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  def before_agent(%__MODULE__{banned_keywords: words}, state, _runtime) do
    content =
      state
      |> Map.get(:messages, [])
      |> Enum.find(&match?(%Message{role: :user}, &1))
      |> case do
        nil -> ""
        message -> Message.text(message) |> String.downcase()
      end

    if Enum.any?(words, &String.contains?(content, &1)) do
      %{
        messages: [
          Message.assistant(
            "I cannot process that request. Please rephrase it."
          )
        ],
        jump_to: :end
      }
    else
      nil
    end
  end
end
```

Attach it like any other middleware:

```elixir
middleware [
  {MyApp.ContentFilterMiddleware,
   banned_keywords: ["credential theft", "exploit production"]}
]
```

### After-Agent Guardrails

Use `after_agent` to validate the final answer before returning it. This is a
good place for model-based safety checks or final business-rule validation.

```elixir
defmodule MyApp.SafetyGuardrailMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Overwrite

  defstruct [:safety_model]

  def new(opts), do: %__MODULE__{safety_model: Keyword.fetch!(opts, :model)}

  def name(_middleware), do: :safety_guardrail

  def can_jump_to(_middleware, :after_agent), do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  def after_agent(%__MODULE__{safety_model: model}, state, _runtime) do
    messages = Map.get(state, :messages, [])
    last_index = last_assistant_index(messages)

    with index when is_integer(index) <- last_index,
         %Message{} = last <- Enum.at(messages, index),
         prompt <- safety_prompt(Message.text(last)),
         {:ok, review} <- ChatModel.invoke(model, [Message.user(prompt)]) do
      if String.contains?(String.upcase(Message.text(review)), "UNSAFE") do
        replacement = Message.assistant("I cannot provide that response.")

        %{
          messages: messages |> List.replace_at(index, replacement) |> Overwrite.new(),
          jump_to: :end
        }
      else
        nil
      end
    else
      nil -> nil
      {:error, error} -> {:error, error}
    end
  end

  defp safety_prompt(response) do
    """
    Evaluate whether this response is safe and policy-compliant.
    Reply with only SAFE or UNSAFE.

    Response:
    #{response}
    """
  end

  defp last_assistant_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: :assistant}, index} -> index
      _other -> nil
    end)
  end
end
```

{% hint style="info" %}
**Immutable Message Updates**

Python examples sometimes mutate `last_message.content`. BeamWeaver messages
are structs in graph state. Replace the message list with
`BeamWeaver.Graph.Overwrite` when you need to rewrite final output instead of
appending another assistant message.
{% endhint %}

## Combining Guardrails

Guardrails are layered by ordering middleware in the agent definition. Put
cheap deterministic checks early, then review or model-based checks around the
operations that need them.

```elixir
middleware [
  {MyApp.ContentFilterMiddleware,
   banned_keywords: ["credential theft", "exploit production"]},
  {BeamWeaver.Agent.Middleware.PII,
   type: :email,
   strategy: :redact,
   apply_to_input: true,
   apply_to_output: true},
  {BeamWeaver.Agent.Middleware.HumanInTheLoop,
   interrupt_on: %{"send_email" => true},
   tools: [MyApp.SendEmailTool]},
  {MyApp.SafetyGuardrailMiddleware,
   model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")}
]
```

Order matters:

- `before_agent` and `before_model` hooks run in middleware order.
- `after_model` and `after_agent` hooks run in reverse order.
- Wrap hooks nest, with earlier middleware wrapping later middleware.

## Testing Guardrails

Test deterministic guardrails directly with ExUnit, then run integration tests
through an agent. Use fake or replay models for model-based guardrails so tests
do not depend on live provider calls. For human review, assert that invocation
returns `{:interrupted, interrupt}` and that resume decisions produce the
expected tool messages or final state.

Use `BeamWeaver.Agent.stream_events/3` when your UI needs to observe guardrail
activity in real time. Interrupts, model calls, tool calls, errors, graph
updates, and completion all appear as typed stream envelopes.

{% hint style="warning" %}
**Testing Platform Scope**

LangChain's guardrails page links to LangSmith testing. BeamWeaver's current
testing path is ExUnit plus BeamWeaver tracing and conformance helpers. There
is no BeamWeaver-specific LangSmith agent test runner.
{% endhint %}

## Related Guides

- [Middleware](middleware.md)
- [Custom Middleware](custom_middleware.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Runtime](runtime.md)
- [Agents](agents.md)
- [Context Engineering](context_engineering.md)
- [Tools](tools.md)
- [Short-Term Memory](short_term_memory.md)
- [Event Streaming](event_streaming.md)
- [Structured Output](structured_output.md)
