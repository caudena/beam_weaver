# Guardrails

Guardrails check inputs, actions and outputs at different points in a run.
Choose the boundary that matters: rejecting a request, authorizing a tool,
redacting displayed text and limiting resource use are separate operations.
A model instruction alone does not enforce any of them.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Redact personal data

After [Installation](installation.md), run this OpenAI example. It checks the
saved input as well as successful completion:

```elixir
defmodule MyApp.RedactedAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
  system_prompt "Acknowledge the user's message briefly."
  middleware [{BeamWeaver.Agent.Middleware.PII, type: :email, strategy: :redact}]
end

{:ok, result} = MyApp.RedactedAgent.invoke(%{messages: ["Contact me at ada@example.com."]})
input = result.messages |> hd() |> BeamWeaver.Core.Message.text()
false = input =~ "ada@example.com"
true = input =~ "[REDACTED_EMAIL]"
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

PII detection is local and pattern-based. Strategies are redact, mask, hash
and block; types include email, credit card, IP, MAC address and URL.
`detector:` adds custom patterns. Input is checked by default; enable
`apply_to_tool_results:` and `apply_to_output:` for those text boundaries.

Message-text redaction leaves other data intact: tool arguments, reasoning,
media, structured response maps, artifacts and metadata. Inventory the data
your application stores or exports. Encryption protects stored data at rest;
it does not remove sensitive fields from a trace or external tool request.

## Block a request

Use a before hook for a rule your application can decide without a model.
Here the caller's account state is validated before any provider call:

```elixir
defmodule MyApp.ActiveAccounts do
  use BeamWeaver.Agent.Middleware

  @impl true
  def before_agent(_middleware, _state, runtime) do
    if runtime.context.account_active do
      nil
    else
      {:error, BeamWeaver.Core.Error.new(:account_disabled, "This account cannot start agent runs.")}
    end
  end
end

defmodule MyApp.AccountAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
  middleware [MyApp.ActiveAccounts]

  context_schema do
    field :account_active, :boolean, required: true
  end
end

{:error, denied} = MyApp.AccountAgent.invoke(%{messages: ["Hello."]}, context: %{account_active: false})
:account_disabled = denied.type
{:ok, allowed} = MyApp.AccountAgent.invoke(%{messages: ["Hello."]}, context: %{account_active: true})
true = byte_size(allowed.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

Get account state from your application, not the prompt. Returning
`{:jump, :end, update}` instead of an error produces an intentional answer
without calling the model. A keyword blocklist can be a product policy, but
is not a general defense against harmful actions or prompt injection.

## Check the answer

`after_model/3` checks each reply before requested tools execute;
`after_agent/3` checks the final state. To replace a message, preserve its ID.
A fresh ID appends another message instead. Use structured data validation
when downstream code depends on answer fields.

Output hooks run after generation. Streamed text may already have left the
server. Buffer output until approval when that boundary must be strict, or
apply an appropriate [stream transform](streaming.md#redact-a-stream).
Per-token pattern replacement can miss values split across token boundaries.

Replace a disallowed output while retaining its ID. This local wording policy is deliberately narrow:

```elixir
defmodule MyApp.NoGuarantees do
  use BeamWeaver.Agent.Middleware
  @impl true
  def after_agent(_middleware, state, _runtime) do
    answer = List.last(state.messages)

    if BeamWeaver.Core.Message.text(answer) =~ ~r/guarantee/i,
      do: %{messages: [%{answer | content: "A teammate must confirm the refund terms."}]}
  end
end

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 128, timeout: 60_000],
    system_prompt: "For this wording demonstration, reply exactly: We guarantee a full refund today.",
    middleware: [MyApp.NoGuarantees]
  )

{:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Return the demonstration sentence."]})
"A teammate must confirm the refund terms." = BeamWeaver.Core.Message.text(List.last(result.messages))
2 = length(result.messages)
```

## Limit model and tool calls

Set `ModelCallLimit` and `ToolCallLimit` for per-run or checkpointed
per-thread limits. Configure `recursion_limit`, provider timeouts and a whole
`run_timeout` for different resource boundaries. Limits constrain work; they
do not decide whether a particular action is authorized.
[Built-in Middleware](builtin_middleware.md#limits) lists exit policies.

## Require approval

Use `interrupt_on` for actions a person must review before execution.
The reviewer must see the actual tool arguments and have permission to approve
that action. Resume using the same saved thread and fresh caller context.
[Human Review](human_in_the_loop.md) shows approval, editing and rejection.

## Block risky tool calls

`AutoMode` asks a decision model to assess selected tool calls using their
description and recent conversation. A risk probability below 0.5 permits
the call; otherwise it returns a blocked tool result. Refusal blocks; a
classifier failure fails the run without executing the tool.

Configure `classifier:` explicitly for the integration you use. The default
is TypeSafe's Jev; OpenAI decisions are another supported option. `tools:`
selects guarded actions and `instructions:` controls classification criteria.
This makes additional model requests. It is a probabilistic policy layer,
not a replacement for tool-side authorization or human approval.

This agent asks a real decision model to assess a requested file write. The file is created only if the policy permits the tool:

```elixir
defmodule MyApp.WriteDraft do
  use BeamWeaver.Tool
  name "write_draft"
  description "Write the requested text to draft.txt in this request's temporary workspace."
  injected :context, :context

  schema do
    field :text, :string
  end

  @impl true
  def invoke(_tool, %{"text" => text, context: context}, _opts) do
    with :ok <- File.write(Path.join(context.root, "draft.txt"), text), do: {:ok, "Draft saved."}
  end
end

defmodule MyApp.CheckedWriter do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Write the requested draft using write_draft, then confirm."
  tools [MyApp.WriteDraft]
  middleware [{BeamWeaver.Agent.Middleware.AutoMode, tools: ["write_draft"], classifier: "openai:gpt-6-luna"}]
end

root = Path.join(System.tmp_dir!(), "beam-weaver-guardrail-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)

try do
  {:ok, result} =
    MyApp.CheckedWriter.invoke(%{messages: ["Write draft.txt with exactly: Order A-1001 arrives Thursday."]},
      context: %{root: root}
    )

  "Order A-1001 arrives Thursday." = File.read!(Path.join(root, "draft.txt"))
  true = Enum.any?(result.messages, &(&1.role == :tool and &1.name == "write_draft"))
after
  File.rm_rf!(root)
end
```

## Moderate with a model

A custom wrapper can call a second model and fail closed if the check fails.
For OpenAI's moderation endpoint, `OpenAIModeration` supports `check_input:`
and `check_output:` and requires its own OpenAI credentials. Moderation
classifies content; it does not verify ownership or transaction eligibility.

Check a benign message with the actual moderation endpoint, then attach that same policy to an agent:

```elixir
alias BeamWeaver.Agent.Middleware.OpenAIModeration
moderation = OpenAIModeration.new(check_input: true, check_output: true, exit_behavior: :error)
{:ok, %{"flagged" => false}} = OpenAIModeration.moderate(moderation, "Please explain parcel tracking.")

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 128, timeout: 60_000],
    middleware: [moderation]
  )

{:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Explain parcel tracking briefly."]})
true = byte_size(BeamWeaver.Core.Message.text(List.last(result.messages))) > 0
```

## Handle a filtered reply

Some providers return a partial or filtered reply as a normal response.
`BeamWeaver.Provider.Outcome.classify/1` exposes a `turn_disposition` such as
`:filtered`. Inspect this before presenting the answer as complete. Your
policy can fail immediately or request one bounded correction.

Other providers normalize safety failures into errors. Handle both outcomes;
HTTP success and a nonempty string alone are not sufficient completion checks.

## Order

Place cheap input checks before expensive calls. Before hooks run in declared
order, wrappers nest and after hooks run in reverse. Avoid later middleware
reintroducing content or tools an earlier policy removed. See [Middleware](middleware.md#order).

## Test guardrails

Exercise both accepted and rejected inputs, verify the protected tool was or
was not executed, and check persisted state as well as displayed text. Use
scripted models for deterministic branch coverage and real providers for
integration checks. [Testing](testing.md) provides the application patterns.
