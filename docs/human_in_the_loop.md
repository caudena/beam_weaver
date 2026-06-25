# Human-In-The-Loop

Human-in-the-loop (HITL) review lets a graph or agent pause and wait for an
external decision before continuing. Use it for approval, review and edit
flows, form collection, or any workflow where the next step depends on a human
or service outside the graph.

BeamWeaver has two layers:

- `BeamWeaver.Graph.interrupt/1` is the low-level graph primitive. Call it from
  a graph node when you want to pause at an application-defined point.
- `BeamWeaver.Agent.Middleware.HumanInTheLoop` is the agent tool-review layer.
  It packages selected tool calls into a standard review payload and applies
  approve, edit, reject, or respond decisions on resume.

`BeamWeaver.Agent.Middleware.HumanInTheLoop` checks model-proposed tool calls
against a policy. When review is required, the middleware emits a graph
interrupt before tool execution. The interrupted state is saved through the
configured checkpointer, and the run resumes after your UI, CLI, or service
passes back review decisions.

{% hint style="info" %}
**BeamWeaver Shape**

LangChain's Python documentation uses `create_agent`, `GraphOutput.interrupts`,
`Command(resume=...)`, `version="v2"`, and `stream_mode` chunks. BeamWeaver
uses `use BeamWeaver.Agent` or `BeamWeaver.Agent.build/1`,
`{:interrupted, interrupt}` tagged results, `BeamWeaver.Graph.Compiled.resume/3`,
your agent module's generated `resume/3` or `resume_review/3`, and typed event
envelopes from generated `stream_events/3`.
{% endhint %}

## Basic Agent Configuration

For Deep Agents-style tool review, set `interrupt_on` directly on the agent.
BeamWeaver turns this option into `BeamWeaver.Agent.Middleware.HumanInTheLoop`
and pauses after the model proposes a matching tool call, before the tool
executes.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "hitl-review-1"}}

{:ok, agent} =
  Agent.build(
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
    tools: [
      MyApp.Tools.RemoveFile,
      MyApp.Tools.FetchFile,
      MyApp.Tools.NotifyEmail
    ],
    interrupt_on: %{
      "remove_file" => true,
      "fetch_file" => false,
      "notify_email" => %{allowed_decisions: [:approve, :reject]}
    },
    checkpointer: checkpointer
  )

case Agent.invoke(
       agent,
       %{messages: [Message.user("Delete temp.txt and email the admin.")]},
       config: config
     ) do
  {:interrupted, interrupt} ->
    IO.inspect(interrupt.value.action_requests, label: "pending tool reviews")

    Agent.resume(
      agent,
      %{decisions: [%{type: :approve}, %{type: :reject}]},
      config: config
    )

  {:ok, state} ->
    {:ok, state}
end
```

Module-defined agents use the `interrupt_on` DSL:

```elixir
defmodule MyApp.ReviewedAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6")

  tools do
    tool MyApp.Tools.RemoveFile
    tool MyApp.Tools.FetchFile
    tool MyApp.Tools.NotifyEmail
  end

  interrupt_on %{
    "remove_file" => true,
    "fetch_file" => false,
    "notify_email" => %{allowed_decisions: [:approve, :reject]}
  }
end
```

`true` enables the default decisions for a tool: `:approve`, `:edit`,
`:reject`, and `:respond`. `false` disables review for that tool. A map can
restrict decisions with `:allowed_decisions`, gate review with `:when` or
`:predicate`, and add review metadata such as `:description` or `:args_schema`.

{% hint style="warning" %}
**Checkpoint Required**

Human review requires a checkpointer and a stable thread ID because the run
pauses and resumes from persisted graph state. Use `BeamWeaver.Checkpoint.ETS`
for local development or tests, and a durable checkpointer such as
`BeamWeaver.Checkpoint.Ecto` in production.
{% endhint %}

## Pause Using Interrupt

Call `BeamWeaver.Graph.interrupt/1` inside a graph node to pause execution and
surface a JSON-safe payload to the caller:

```elixir
alias BeamWeaver.Graph

approval_node = fn state ->
  approved =
    Graph.interrupt(%{
      question: "Approve this action?",
      details: state.action_details
    })

  %{approved: approved}
end
```

When the graph reaches the interrupt:

1. Execution pauses inside the node.
2. The checkpointer saves the current thread state.
3. The caller receives `{:interrupted, interrupt}`.
4. The graph waits until the same thread is resumed.
5. The resume value becomes the return value of `Graph.interrupt/1`.

Interrupt payloads should be maps, lists, strings, numbers, booleans, or `nil`
when possible. Persistent checkpointers must be able to serialize both the
interrupt payload and the eventual resume value.

{% hint style="warning" %}
**Checkpoint Required**

Dynamic interrupts need a checkpointer and a stable `thread_id`. Use
`BeamWeaver.Checkpoint.ETS` for tests or local prototypes. Use
`BeamWeaver.Checkpoint.Ecto` for durable Postgres-backed deployments. Always
resume with the same `config`.
{% endhint %}

## Resuming Interrupts

Resume a paused graph with `BeamWeaver.Graph.Compiled.resume/3` and the same
thread configuration:

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "approval-1"}}

graph =
  Graph.new(name: "ApprovalFlow")
  |> Graph.add_node(:approval, approval_node)
  |> Graph.add_edge(Graph.start(), :approval)
  |> Graph.add_edge(:approval, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

{:interrupted, interrupt} =
  Compiled.invoke(
    graph,
    %{action_details: "Transfer $500"},
    config: config
  )

IO.inspect(interrupt.value, label: "waiting for")

{:ok, state} =
  Compiled.resume(graph, true, config: config)

state.approved
#=> true
```

If the intended resume value is `nil`, use `Graph.null_resume()` so BeamWeaver
can distinguish "resume with nil" from "no resume value was supplied":

```elixir
Compiled.resume(graph, Graph.null_resume(), config: config)
```

BeamWeaver also accepts `%BeamWeaver.Graph.Command{resume: value}` as graph
input for command-driven graph control. For application
code, `Compiled.resume/3` is usually clearer because it says directly that the
run is continuing an interrupted checkpoint.

{% hint style="info" %}
**No `GraphOutput.interrupts`**

LangGraph's Python examples use `result.interrupts` for `version="v2"` and
`result["__interrupt__"]` for the older invoke shape. BeamWeaver returns a
tagged result: `{:interrupted, interrupt}`. Inspect `interrupt.value`,
`interrupt.id`, `interrupt.node`, and related fields instead.
{% endhint %}

## Handling Multiple Interrupts

Parallel branches can pause at the same super-step. When there is more than one
pending interrupt, resume with a map keyed by interrupt ID:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

graph =
  Graph.new(name: "ParallelQuestions")
  |> Graph.add_reducer(:answers, fn existing, update ->
    existing ++ List.wrap(update)
  end)
  |> Graph.add_node(:left, fn _state ->
    answer = Graph.interrupt("question_a")
    %{answers: ["a:#{answer}"]}
  end)
  |> Graph.add_node(:right, fn _state ->
    answer = Graph.interrupt("question_b")
    %{answers: ["b:#{answer}"]}
  end)
  |> Graph.add_edge(Graph.start(), :left)
  |> Graph.add_edge(Graph.start(), :right)
  |> Graph.add_edge(:left, Graph.end_node())
  |> Graph.add_edge(:right, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

{:interrupted, _interrupt} =
  Compiled.invoke(graph, %{answers: []}, config: config)

{:ok, snapshot} =
  Compiled.get_state(graph, config)

resume_values =
  Map.new(snapshot.interrupts, fn interrupt ->
    {interrupt.id, "answer for #{interrupt.value}"}
  end)

{:ok, state} =
  Compiled.resume(graph, resume_values, config: config)
```

When only one interrupt is pending, a scalar resume value is accepted. When
multiple interrupts are pending, use the map shape so each answer is paired
with the intended paused task.

## Approval, Review, And Validation Patterns

Use `interrupt/1` directly when the graph itself owns the human interaction.
For example, approve or cancel a branch:

```elixir
alias BeamWeaver.Graph.Command

approval_node = fn state ->
  decision =
    BeamWeaver.Graph.interrupt(%{
      question: "Proceed?",
      details: state.action_details
    })

  if decision do
    %Command{goto: :proceed}
  else
    %Command{goto: :cancel}
  end
end
```

Review and edit generated state:

```elixir
review_node = fn state ->
  edited =
    BeamWeaver.Graph.interrupt(%{
      instruction: "Review and edit this draft",
      content: state.generated_text
    })

  %{generated_text: edited}
end
```

Validate human input by interrupting again when the resume value is invalid:

```elixir
age_node = fn _state ->
  ask_age = fn ask, prompt ->
    answer = BeamWeaver.Graph.interrupt(prompt)

    if is_integer(answer) and answer > 0 do
      answer
    else
      ask.(ask, "'#{answer}' is not a valid age. Please enter a positive number.")
    end
  end

  age = ask_age.(ask_age, "What is your age?")

  %{age: age}
end
```

The node restarts from the beginning on each resume, so keep the interrupt
sequence deterministic. See [Rules Of Interrupts](#rules-of-interrupts).

## Decision Types

BeamWeaver supports the same four review decisions as LangChain:

| Decision | Behavior | Common use |
| --- | --- | --- |
| `:approve` | Execute the original tool call as-is. | Send an approved email draft. |
| `:edit` | Execute a modified tool call. | Change the recipient, query, or file path before running. |
| `:reject` | Skip execution and add rejection feedback as an error tool message. | Tell the agent why a proposed action is not allowed. |
| `:respond` | Skip execution and use the human's message as the successful tool result. | Implement an `ask_user` tool where the human is the tool backend. |

Allowed decisions are configured per tool. If multiple tool calls are paused in
one interrupt, provide one decision for each action in the same order as the
interrupt's `action_requests`.

{% hint style="warning" %}
**Edit Conservatively**

`edit` can change the tool name and arguments before execution. Keep edits
small and compatible with the original tool call. Large semantic changes may
cause the model to reassess and call more tools than you expected.
{% endhint %}

## Advanced Middleware Configuration

Top-level `interrupt_on` is the usual path. Add
`BeamWeaver.Agent.Middleware.HumanInTheLoop` manually when you need custom
middleware ordering, a custom `description_prefix`, or explicit tool schemas for
early validation of edited arguments. `interrupt_on` maps tool names to review
policies:

```elixir
defmodule MyApp.ReviewedAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.HumanInTheLoop

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  tools do
    tool MyApp.Tools.WriteFile
    tool MyApp.Tools.ExecuteSQL
    tool MyApp.Tools.ReadData
  end

  middleware do
    use HumanInTheLoop,
      interrupt_on: %{
        "write_file" => true,
        "execute_sql" => %{allowed_decisions: [:approve, :reject]},
        "read_data" => false
      },
      description_prefix: "Tool execution pending approval",
      tools: [MyApp.Tools.WriteFile, MyApp.Tools.ExecuteSQL, MyApp.Tools.ReadData]
  end
end
```

`true` enables all decisions for that tool: `:approve`, `:edit`, `:reject`,
and `:respond`. `false` means the middleware will not interrupt that tool.

Useful middleware options:

| Option | Meaning |
| --- | --- |
| `:interrupt_on` | Required map of tool names to `true`, `false`, or a review config map. |
| `:interrupt_mode` | `:all` reviews all matching calls in a model response; `:first` pauses on the first matching call. |
| `:description_prefix` | Prefix used for generated review descriptions. Defaults to `"Tool execution requires approval"`. |
| `:tools` | Tool modules or structs used to validate edited tool arguments against tool schemas. |

Review config options:

| Option | Meaning |
| --- | --- |
| `:allowed_decisions` | List of allowed decision atoms or strings: `:approve`, `:edit`, `:reject`, `:respond`. |
| `:description` | Static description string, or a function with arity 2 or 3. |
| `:args_schema` | Optional argument schema included in the review config for UI validation. |
| `:when` / `:predicate` | Function with arity 1, 2, or 3. Return `true` to review this call. |

`description` functions receive the tool call and state. Arity-3 functions also
receive runtime:

```elixir
middleware do
  use BeamWeaver.Agent.Middleware.HumanInTheLoop,
    interrupt_on: %{
      "execute_sql" => %{
        allowed_decisions: [:approve, :reject],
        description: fn call, _state, runtime ->
          context = runtime.context || %{}
          user = Map.get(context, :user_id) || Map.get(context, "user_id", "unknown")
          args = Map.get(call, :args, Map.get(call, "args", %{}))
          "SQL requested by #{user}: #{inspect(args)}"
        end
      }
    }
end
```

Predicate functions receive the tool call, optionally the graph state, and
optionally runtime. Use `interrupt_mode: :first` with predicates when one
approval should pause a multi-tool response before any later matching calls are
reviewed.

{% hint style="warning" %}
**Checkpoint Required**

HITL requires a checkpointer because the graph must persist state while the run
is paused. Use `BeamWeaver.Checkpoint.ETS` for tests or local prototypes. Use a
persistent checkpointer such as `BeamWeaver.Checkpoint.Ecto` for durable
deployments. Always resume with the same thread ID in `config`.
{% endhint %}

## Respond To Interrupts

Invoke the agent with a checkpointer and a stable thread ID. A reviewed tool call
returns `{:interrupted, interrupt}` instead of completing the run.

```elixir
alias BeamWeaver.Agent.HITL
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "review-thread-1"}}

case MyApp.ReviewedAgent.invoke(
       %{messages: [Message.user("Delete old records from the database.")]},
       checkpointer: checkpointer,
       config: config
     ) do
  {:interrupted, interrupt} ->
    {:ok, review} = HITL.from_interrupt(interrupt)

    Enum.each(review.action_requests, fn action ->
      IO.inspect(action, label: "pending action")
    end)

    MyApp.ReviewedAgent.resume(
      %{decisions: [%{type: :approve}]},
      checkpointer: checkpointer,
      config: config
    )

  {:ok, state} ->
    {:ok, state}

  {:error, error} ->
    {:error, error}
end
```

The interrupt value contains the review payload:

```elixir
%{
  action_requests: [
    %{
      name: "execute_sql",
      args: %{"query" => "DELETE FROM records WHERE created_at < NOW() - INTERVAL '30 days';"},
      description: "Tool execution pending approval\n\nTool: execute_sql\nArgs: ..."
    }
  ],
  review_configs: [
    %{
      action_name: "execute_sql",
      allowed_decisions: ["approve", "reject"]
    }
  ]
}
```

`BeamWeaver.Agent.HITL.from_interrupt/1` is optional, but it is useful for
turning raw interrupt maps into framework-agnostic review structs that Phoenix,
LiveView, CLI, or API code can render safely.

{% hint style="info" %}
**No LangGraph Command Object**

Python examples resume with `Command(resume=...)`. BeamWeaver resume values are
plain maps, raw decision lists, or `%BeamWeaver.Agent.HITL.Decision{}` structs.
Use `resume/3` when you already have `%{decisions: [...]}`. Use
`resume_review/3` when you want BeamWeaver to normalize a raw decision list or
decision structs for you.
{% endhint %}

## Resume Decisions

### Approve

Approve the original tool call and continue execution:

```elixir
MyApp.ReviewedAgent.resume(
  %{decisions: [%{type: :approve}]},
  checkpointer: checkpointer,
  config: config
)
```

### Edit

Edit the tool call before execution:

```elixir
MyApp.ReviewedAgent.resume(
  %{
    decisions: [
      %{
        type: :edit,
        edited_action: %{
          name: "execute_sql",
          args: %{
            "query" => "DELETE FROM records WHERE status = 'archived' AND created_at < NOW() - INTERVAL '30 days';"
          }
        }
      }
    ]
  },
  checkpointer: checkpointer,
  config: config
)
```

When `:tools` or `:args_schema` is provided, BeamWeaver validates edited
arguments before allowing the tool call to continue.

### Reject

Reject the tool call and send feedback to the model as a tool error:

```elixir
MyApp.ReviewedAgent.resume(
  %{
    decisions: [
      %{
        type: :reject,
        message: "Do not delete records. Ask for a date range and dry-run count first."
      }
    ]
  },
  checkpointer: checkpointer,
  config: config
)
```

### Respond

Use `:respond` when the tool's real backend is the human reply. BeamWeaver
skips the tool implementation and returns the human message as a successful tool
result:

```elixir
MyApp.ReviewedAgent.resume_review(
  [
    HITL.decision(:respond, message: "Blue.")
  ],
  checkpointer: checkpointer,
  config: config
)
```

### Multiple Decisions

Provide one decision per pending action, in interrupt order:

```elixir
%{
  decisions: [
    %{type: :approve},
    %{
      type: :edit,
      edited_action: %{
        name: "send_email",
        args: %{"to" => "legal@example.com", "subject" => "Review needed"}
      }
    },
    %{type: :reject, message: "This action is not allowed for the current user."}
  ]
}
```

## Subagent Interrupts

Synchronous `BeamWeaver.Agent.Subagent.Spec` subagents are normal BeamWeaver
agents under the hood. The parent agent's `interrupt_on` configuration is passed
to generated subagents unless the subagent supplies its own review map:

```elixir
alias BeamWeaver.Agent.Subagent

BeamWeaver.Agent.build(
  model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
  tools: [MyApp.Tools.DeleteFile, MyApp.Tools.ReadFile],
  interrupt_on: %{
    "delete_file" => true,
    "read_file" => false
  },
  subagents: [
    Subagent.Spec.new(
      name: "file-manager",
      description: "Manages file operations.",
      system_prompt: "Review filesystem work carefully.",
      tools: [MyApp.Tools.DeleteFile, MyApp.Tools.ReadFile],
      interrupt_on: %{
        "delete_file" => true,
        "read_file" => true
      }
    )
  ],
  checkpointer: checkpointer
)
```

If that subagent triggers a review, the parent run returns the same
`{:interrupted, interrupt}` shape and resumes with the same thread config.

{% hint style="info" %}
**Subagent Override Shape**

For `Subagent.Spec`, provide a custom `interrupt_on` map to change child review
behavior. The current implementation treats `nil` and `false` as inheritance
for this subagent field, so `false` is not a child-level opt-out from a parent
policy. To avoid review in a child, provide a narrower map, remove the sensitive
tool from that child, or use a prebuilt compiled subagent with its own
middleware stack.
{% endhint %}

`BeamWeaver.Agent.Subagent.Compiled` uses the agent you provide. Configure HITL
on that compiled agent directly. Async subagents run behind their own remote
client; protect supervisor-side async tools such as `start_async_task` or
`cancel_async_task` with parent `interrupt_on` when those operations need
approval.

## Streaming With HITL

Use `BeamWeaver.Agent.stream_events/3` when your UI needs live events while the
agent runs. BeamWeaver does not expose Python's `stream_mode=["updates",
"messages"]` chunks; it returns typed stream envelopes or an interrupted result
with the events collected up to the pause.

```elixir
alias BeamWeaver.Stream.Envelope

case MyApp.ReviewedAgent.stream_events(
       %{messages: [Message.user("Delete old records from the database.")]},
       checkpointer: checkpointer,
       config: config
     ) do
  {:interrupted, interrupt} ->
    IO.inspect(interrupt.value.action_requests, label: "review required")

    for %Envelope{} = envelope <- interrupt.events do
      IO.inspect(envelope.event, label: "event before interrupt")
    end

  {:ok, events} ->
    for %Envelope{} = envelope <- events do
      IO.inspect(envelope.event, label: "event")
    end
end
```

{% hint style="warning" %}
**Streaming Resume Shape**

For most application code, call `MyApp.ReviewedAgent.resume/2` or
`resume_review/2` after the human decision. The stream shape is
BeamWeaver-specific and does not support LangChain's `version: "v2"` or
`stream_mode` options.
{% endhint %}

## Execution Lifecycle

The HITL middleware runs in `after_model`, after the model has produced an AI
message and before any tool calls execute:

1. The agent calls the model.
2. The model returns an assistant message, possibly with tool calls.
3. `HumanInTheLoop` inspects the tool calls against `interrupt_on`.
4. Matching calls are packaged as `action_requests` and `review_configs`.
5. The middleware calls `BeamWeaver.Graph.interrupt/1`.
6. The checkpointer stores the paused graph state.
7. A resume decision approves, edits, rejects, or responds to each pending
   action.
8. Approved and edited actions continue to the tool node. Rejected and responded
   actions become synthesized tool messages. The graph then continues normally.

## Custom HITL Logic

Prefer `BeamWeaver.Agent.Middleware.HumanInTheLoop` for tool review. For
specialized graph workflows, you can use the lower-level interrupt primitive
inside a graph node or custom middleware:

```elixir
alias BeamWeaver.Graph

approval_node = fn state ->
  decision =
    Graph.interrupt(%{
      question: "Approve deployment?",
      release: state[:release]
    })

  %{approved_by_human: decision}
end
```

Low-level interrupts are not automatically rendered as HITL review payloads.
Use the middleware when you want the standard `action_requests`,
`review_configs`, and decision handling.

## Interrupts In Tools

The recommended BeamWeaver equivalent of LangGraph's "interrupt inside a tool"
pattern is `BeamWeaver.Agent.Middleware.HumanInTheLoop`. The middleware pauses
after the model proposes tool calls and before the tool node executes them,
which keeps approval logic outside business tool implementations and gives you
consistent `action_requests`, `review_configs`, and decision validation.

```elixir
middleware do
  use BeamWeaver.Agent.Middleware.HumanInTheLoop,
    interrupt_on: %{
      "send_email" => %{
        allowed_decisions: [:approve, :edit, :reject],
        description: "Approve or edit this email before sending."
      }
    },
    tools: [MyApp.Tools.SendEmail]
end
```

Calling `BeamWeaver.Graph.interrupt/1` from arbitrary tool code is not a public
tool API contract. It only works when the tool is executed within a graph task
that has the interrupt scratchpad installed, and it will not produce the
standard HITL review payload. Put reusable approval policy in the middleware
unless you are deliberately writing custom graph runtime code.

## Rules Of Interrupts

Interrupts pause by throwing a private graph control signal. The runtime catches
that signal, persists the checkpoint, and returns `{:interrupted, interrupt}`.
When the graph resumes, the node starts again from the beginning and replay
continues until the interrupted call receives the resume value.

### Do Not Catch The Interrupt Signal

Do not wrap `Graph.interrupt/1` in broad `try/catch` code that catches all
throws. Catching the control signal prevents the runtime from observing the
interrupt.

Good shape:

```elixir
node = fn state ->
  decision = BeamWeaver.Graph.interrupt("Approve?")

  case MyApp.External.call(decision) do
    {:ok, result} -> %{result: result}
    {:error, reason} -> %{error: inspect(reason)}
  end
end
```

Risky shape:

```elixir
node = fn _state ->
  try do
    BeamWeaver.Graph.interrupt("Approve?")
  catch
    _kind, _value ->
      %{error: "caught graph control signal"}
  end
end
```

### Keep Interrupt Order Stable

Within a single node, resume values are matched to interrupt calls by the order
in which that node reaches them. Keep the sequence stable across executions:

```elixir
node = fn _state ->
  name = BeamWeaver.Graph.interrupt("What is your name?")
  age = BeamWeaver.Graph.interrupt("What is your age?")
  city = BeamWeaver.Graph.interrupt("What is your city?")

  %{name: name, age: age, city: city}
end
```

Avoid conditionally skipping interrupts or looping over data whose length may
change between the original run and a resume.

### Keep Payloads Serializable

Interrupt values and resume values should be simple data: maps, lists, strings,
numbers, booleans, and `nil`. Do not put functions, PIDs, ports, anonymous
references, or application structs that your checkpointer cannot serialize into
interrupt payloads.

### Make Earlier Side Effects Idempotent

Code before an interrupt runs again on resume. If a node writes to an external
database, filesystem, queue, email provider, or payment service before it calls
`Graph.interrupt/1`, make that side effect idempotent or move it after the
interrupt.

Safer shape:

```elixir
node = fn state ->
  approved = BeamWeaver.Graph.interrupt("Create audit log?")

  if approved do
    MyApp.Audit.upsert_event!(state.event_id, state.audit_payload)
  end

  %{approved: approved}
end
```

## Using With Subgraphs

If a parent node invokes a subgraph and the subgraph interrupts, BeamWeaver
stores checkpoint namespace metadata so the parent can resume the child
checkpoint. The parent graph is resumed with the same top-level thread config:

```elixir
{:interrupted, interrupt} =
  BeamWeaver.Graph.Compiled.invoke(parent_graph, input, config: config)

{:ok, state} =
  BeamWeaver.Graph.Compiled.resume(
    parent_graph,
    %{interrupt.id => "approved"},
    config: config
  )
```

As with ordinary nodes, code before the interrupted point may run again. Keep
parent-node setup work and child-node setup work deterministic or idempotent.

## Static Breakpoints

Static breakpoints pause before or after named nodes. They are useful for
debugging and state inspection, not for product HITL workflows where the pause
condition belongs in application logic.

Compile a graph with `interrupt_before:` or `interrupt_after:`:

```elixir
graph =
  Graph.new(name: "DebuggableFlow")
  |> Graph.add_node(:load, load)
  |> Graph.add_node(:process, process)
  |> Graph.add_edge(:load, :process)
  |> Graph.add_edge(Graph.start(), :load)
  |> Graph.add_edge(:process, Graph.end_node())
  |> Graph.compile!(
    checkpointer: checkpointer,
    interrupt_before: [:process]
  )

{:interrupted, breakpoint} =
  Compiled.invoke(graph, %{input: "data"}, config: config)

breakpoint.timing
#=> :before

{:ok, state} =
  Compiled.resume(graph, nil, config: config)
```

The agent DSL exposes the same idea:

```elixir
defmodule MyApp.DebugAgent do
  use BeamWeaver.Agent

  interrupt_before [:model]
  interrupt_after [:tools]
end
```

BeamWeaver supports compile-time static breakpoints. It does not expose
LangGraph's per-invocation `interrupt_before` or `interrupt_after` arguments.

{% hint style="info" %}
**Dynamic Interrupts For HITL**

Use `BeamWeaver.Graph.interrupt/1` or `HumanInTheLoop` middleware for user-facing
human review. Static breakpoints are a developer debugging tool.
{% endhint %}

## Related Guides

- [Prebuilt Middleware](prebuilt_middleware.md)
- [Composed Agent Capabilities](agent_harness.md)
- [Subagents](subagents.md)
- [Async Subagents](async_subagents.md)
- [Guardrails](guardrails.md)
- [Runtime](runtime.md)
- [Event Streaming](event_streaming.md)
- [Durable Execution](durable_execution.md)
- [Fault Tolerance](fault_tolerance.md)
- [Tools](tools.md)
- [Agents](agents.md)
- [Context Engineering](context_engineering.md)
- [Short-Term Memory](short_term_memory.md)
