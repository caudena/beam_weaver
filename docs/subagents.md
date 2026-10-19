# Subagents

Delegate a self-contained task when it benefits from a specialist's tools,
prompt or separate context window. The parent receives the child's result;
it does not import every intermediate search and tool call into its messages.
For a fixed application-selected sequence, use [Subgraphs](subgraphs.md).

Complete [Installation](installation.md). Both agents below call OpenAI.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Delegate and capture a structured result

```elixir
defmodule MyApp.PolicyAnswer do
  use BeamWeaver.Schema
  field :refund_days, :integer

  field :source, :string,
    enum: ["supplied_policy"],
    description: "The identifier of the policy supplied in this assignment"
end

defmodule MyApp.PolicyExpert do
  use BeamWeaver.Agent

  name "policy_expert"
  description "Extracts refund timing from policy text included in the assignment."
  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Extract only the supplied facts. Use source supplied_policy."
  tools []
  response_schema MyApp.PolicyAnswer
end

defmodule MyApp.Supervisor do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000

  system_prompt "Delegate policy extraction to policy_expert exactly once. Include the full policy in the task. Then confirm completion."

  subagents do
    subagent MyApp.PolicyExpert, capture_output: :policy
    include [BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)]
  end
end

{:ok, result} = MyApp.Supervisor.invoke(%{messages: ["Extract this policy: Refunds take five business days."]})
%{"refund_days" => 5, "source" => "supplied_policy"} = result.subagent_outputs["policy"]
true = Enum.any?(result.messages, &(&1.role == :tool and &1.name == "task"))
```

The captured map proves the child produced the requested data. The parent
sees a completion notice rather than the full answer unless configured otherwise.
Disable the general-purpose worker when only the named specialist is intended.

## When to delegate

Use delegation to isolate long research, assign specialized tools or run
independent tasks concurrently. A single lookup usually needs only a tool.
Delegation adds model calls and latency; each child needs its own bounds.

## The task tool

`subagents` exposes `task` with `subagent_type` and `description`. The latter
is the complete assignment and normally becomes the child's only user message.
Include facts, constraints, desired output and completion criteria. A child
with `inherit_messages: true` also receives parent conversational context with
tool exchanges removed.

Without capture, the parent receives final assistant text or structured JSON.
Child failure becomes a tool error for the parent to handle; it does not
necessarily fail the whole parent run. Inspect results rather than equating
successful delegation with successful business work.

## Declare subagents

A child module is an ordinary agent with a useful name and description.
`subagent Module, options` can override its declarations.

| Option | Purpose |
| --- | --- |
| `name:`, `description:`, `system_prompt:` | Role and assignment instructions |
| `model:`, `tools:`, `middleware:` | Child execution capabilities |
| `capture_output:` | Store the answer in parent state |
| `execution_mode:` | Loop, one structured call or research then generation |
| `inherit_messages:` | Include filtered parent conversation |
| `interrupt_on:` | Child review policy; false disables inherited review |
| `base_middleware:` | Explicitly request parent workspace/skills/planning capabilities |
| `filesystem:`, `permissions:`, `skills:` | Workspace and access overrides |
| Limits and storage | Child-specific budgets, checkpointer and store |

An omitted tool set can inherit parent tools; `tools: []` prevents that.
Omitted review rules, recursion limits and storage can also inherit. Ordinary
parent middleware such as retries, PII and call limits is **not** automatically
copied to every explicit child. Declare shared policies deliberately.

`base_middleware:` supports filesystem, skills and task-list middleware, plus
`:deepagents` for the general-purpose set including inherited context policy.
Explicit child middleware of the same module replaces that inherited entry.

## Structured output

A child `response_schema` produces JSON for the parent, or a map when captured.
Choose a schema based on what the parent/application needs to decide next.
Structured data does not validate the truth of supplied evidence; keep source
references alongside extracted facts.

## Captured outputs

`capture_output: :key` stores output under the string key in
`result.subagent_outputs`. The default deduplicates the same child/task
description within a saved thread. Configure `dedupe: false` when freshness
requires another execution; use `parent_result: :full` when the parent's model
also needs the answer. Captured output follows checkpoint retention.

## Subagents built at runtime

`BeamWeaver.Agent.Subagent.Spec.new/1` accepts a name, description and agent
options, including `response_format:` for a schema/strategy. A `subagents do`
block can `include` a runtime list. Specs can inherit omitted parent model,
tools and review rules.

Construct a specialist from runtime options, attach it to a parent, and retain its typed answer:

```elixir
specialist =
  BeamWeaver.Agent.Subagent.Spec.new(
    name: "policy_reader",
    description: "Extracts refund timing from supplied policy text.",
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 256, timeout: 60_000],
    system_prompt: "Extract only supplied facts; use source supplied_policy.",
    tools: [],
    response_format: MyApp.PolicyAnswer,
    capture_output: :runtime_policy
  )

{:ok, parent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 512, timeout: 60_000],
    system_prompt: "Delegate to policy_reader exactly once and include the supplied policy.",
    subagents: [specialist, BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)]
  )

{:ok, result} = BeamWeaver.Agent.invoke(parent, %{messages: ["Policy: refunds take five business days."]})
%{"refund_days" => 5} = result.subagent_outputs["runtime_policy"]
```

## Compiled subagents

`Subagent.Compiled` wraps an existing module or built agent as it is. It does
not inherit the parent's tools/review rules and does not apply spec-style
base middleware. It can still use parent storage and recursion limits where
its own are absent. Choose this form when preserving an existing agent's
configuration is the intended contract.

Wrap the existing policy expert without rebuilding its tools or middleware from the parent:

```elixir
child = %BeamWeaver.Agent.Subagent.Compiled{
  name: "policy_expert",
  description: "Extracts supplied policy facts.",
  agent: MyApp.PolicyExpert,
  capture_output: :compiled_policy
}

{:ok, parent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 512, timeout: 60_000],
    system_prompt: "Delegate policy extraction to policy_expert once; include the supplied text.",
    subagents: [child, BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)]
  )

{:ok, result} = BeamWeaver.Agent.invoke(parent, %{messages: ["Refunds take five business days."]})
%{"refund_days" => 5} = result.subagent_outputs["compiled_policy"]
```

## Checked when the agent is built

Parent validation checks child definitions for invalid models, tools,
middleware, response formats and unknown options; errors identify the child.
Actual construction is deferred until delegation. Module-level validation is
cached until code changes, so dynamic data sources should be validated when
your application updates them, not assumed to be freshly checked every call.

## The general-purpose subagent

The default worker shares the parent's model, ordinary tools, workspace,
skills and selected context/profile policies, but not all parent middleware
or a task list. Configure it with `GeneralPurposeSubagentProfile`, disable it
as above, or replace it with a child named `"general-purpose"`.

## Execution modes

| Mode | Work performed |
| --- | --- |
| `:agent_loop` | Normal tool/model loop |
| `:structured_once` | One structured model answer |
| `:research_then_generate` | Research with tools, then a tool-free formatting call |

The last mode separates evidence gathering from structured generation.
Account for both phases in limits. An explicit child `ModelCallLimit` replaces
the default one-call limit of structured-once mode.
The child’s system prompt is reused in both phases. Make tool instructions
conditional on tools being available, and tell the generation phase to use
the research context it receives.

For extraction with no research phase, declare a single structured call and run the module as a child:

```elixir
defmodule MyApp.OnePassPolicy do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Extract the refund timing. Set source to supplied_policy."
  tools []
  response_schema MyApp.PolicyAnswer
  execution_mode :structured_once
end

child =
  BeamWeaver.Agent.Subagent.Spec.from_agent_module(MyApp.OnePassPolicy,
    name: "one_pass_policy",
    description: "Extracts supplied policy facts in one pass.",
    capture_output: :one_pass
  )

{:ok, parent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 512, timeout: 60_000],
    system_prompt: "Delegate once to one_pass_policy and include the policy text.",
    subagents: [child, BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)]
  )

{:ok, answer} = BeamWeaver.Agent.invoke(parent, %{messages: ["Refunds take five business days."]})
%{"refund_days" => 5, "source" => "supplied_policy"} = answer.subagent_outputs["one_pass"]
```

For research-then-generation, the child first obtains evidence with a tool, then formats its final answer without tools. An observer confirms the lookup actually ran:

```elixir
defmodule MyApp.ReadPolicyFact do
  use BeamWeaver.Tool
  name "read_policy_fact"
  description "Read the sample refund timing policy."
  injected :context, :context

  schema do
  end

  @impl true
  def invoke(_tool, %{context: context}, _opts) do
    send(context.observer, :policy_fact_read)
    {:ok, "Refunds take five business days. Source: supplied_policy."}
  end
end

defmodule MyApp.ResearchPolicy do
  use BeamWeaver.Agent
  name "research_policy"
  description "Reads and extracts the sample policy."
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000

  system_prompt "When read_policy_fact is available, call it to obtain the policy. When research context is supplied instead, extract only those supplied facts."

  tools [MyApp.ReadPolicyFact]
  response_schema MyApp.PolicyAnswer
  execution_mode :research_then_generate
end

child = BeamWeaver.Agent.Subagent.Spec.from_agent_module(MyApp.ResearchPolicy, capture_output: :researched)

{:ok, parent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 512, timeout: 60_000],
    system_prompt:
      "Delegate to research_policy once, then confirm completion. The application reads the captured answer.",
    subagents: [child, BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)]
  )

{:ok, answer} =
  BeamWeaver.Agent.invoke(parent, %{messages: ["Read and report the refund timing policy."]},
    context: %{observer: self()}
  )

%{"refund_days" => 5, "source" => "supplied_policy"} = answer.subagent_outputs["researched"]

receive do
  :policy_fact_read -> :ok
after
  0 -> raise "Research tool was never executed"
end
```

## Context and shared state

Children receive parent runtime context and selected public state, excluding
parent messages unless requested, task lists and private bookkeeping. Child
state changes can propagate back, including state-backed files. This is not
process-level data isolation: give specialists only the state and capabilities
they should use.

With checkpoints, children use nested namespaces in the parent thread unless
they supply storage. A child with its own saver under a parent without a thread
uses a run-derived thread identity. Use stable application threading when
results must be resumed later.

This tool records a flag; it does not transfer money. Trusted context reaches the child and its state update reaches the parent:

```elixir
defmodule MyApp.Tools.FlagForRefund do
  use BeamWeaver.Tool

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command

  name "flag_for_refund"
  description "Flag one of the current customer's orders for a refund."

  injected :context, :context
  injected :tool_call_id, :tool_call_id

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id, context: context, tool_call_id: id}, _opts) do
    flag = "#{context.customer_id}/#{order_id}"
    {:ok, %Command{update: %{refund_flag: flag, messages: [Message.tool("Flagged #{flag}.", tool_call_id: id)]}}}
  end
end

defmodule MyApp.RefundClerk do
  use BeamWeaver.Agent
  name "refund_clerk"
  description "Records a refund flag in application state."
  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Use flag_for_refund once for the assigned order, then confirm."
  tools [MyApp.Tools.FlagForRefund]
end

defmodule MyApp.FlagSupervisor do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Delegate the requested flag to refund_clerk exactly once, including the order ID."

  subagents do
    subagent MyApp.RefundClerk
    include [BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)]
  end
end

{:ok, result} =
  MyApp.FlagSupervisor.invoke(%{messages: ["Flag A-1001 for refund review."]}, context: %{customer_id: "cus_ada"})

"cus_ada/A-1001" = result.refund_flag
```

## Streaming

Child events arrive in the parent's stream with a subagent namespace and
metadata identifying the child and originating task call. Match on those IDs
to keep concurrent work separate. `Subagent.StreamTransformer` summarizes
child runs, including nested status and values. Do not re-enumerate a live
stream to obtain a second view; collect or dispatch once.

Inspect parent and child tool events from one consumed stream:

```elixir
alias BeamWeaver.Stream.Events

{:ok, events} =
  MyApp.FlagSupervisor.stream_events(%{messages: ["Please refund order A-1001."]},
    live: true,
    context: %{customer_id: "cus_ada"}
  )

calls = for %{event: %Events.ToolStart{tool_name: tool}, namespace: namespace} <- events, do: {namespace, tool}
true = Enum.any?(calls, fn {_, tool} -> tool == "task" end)
true = Enum.any?(calls, fn {namespace, tool} -> namespace != [] and tool == "flag_for_refund" end)
```

Project the same kind of stream into child run summaries:

```elixir
alias BeamWeaver.Agent.Subagent.{RunStream, StreamTransformer}

{:ok, events} =
  MyApp.FlagSupervisor.stream_events(
    %{messages: ["Please refund order A-1001."]},
    context: %{customer_id: "cus_ada"}
  )

transformer = StreamTransformer.new(subagent_names: ["refund_clerk"])
{:ok, transformer, _updates} = StreamTransformer.process_many(transformer, events)
[run] = StreamTransformer.finalize(transformer).log
{:completed, "refund_clerk"} = {run.status, RunStream.name(run)}
true = is_map(RunStream.output(run))
```

## Human review

Nested tool review pauses the parent; resume_review on the parent continues
that child. A parent whose descendants require review needs a checkpointer.
Explicit child rules override inherited ones, and false can disable them.

Multiple child reviews and already-completed siblings retain their execution
state. A new parent message can cancel pending review without undoing work
already completed. Bind review UI submissions to current saved state; see
[Human Review](human_in_the_loop.md).

Override the child’s review rule and resume through the parent using the same saved thread:

```elixir
child = BeamWeaver.Agent.Subagent.Spec.from_agent_module(MyApp.RefundClerk, interrupt_on: %{"flag_for_refund" => true})

{:ok, parent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 512, timeout: 60_000],
    system_prompt: "Delegate A-1001 to refund_clerk so the runtime can review its flag request.",
    subagents: [child, BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)]
  )

opts = [
  checkpointer: BeamWeaver.Checkpoint.ETS.new(),
  config: %{"configurable" => %{"thread_id" => "child-review"}},
  context: %{customer_id: "cus_ada"}
]

{:interrupted, interrupt} =
  BeamWeaver.Agent.invoke(parent, %{messages: ["Submit A-1001 for refund flag review."]}, opts)

{:ok, review} = BeamWeaver.Agent.HITL.from_interrupt(interrupt)
"flag_for_refund" = hd(review.action_requests).name
{:ok, result} = BeamWeaver.Agent.resume_review(parent, [BeamWeaver.Agent.HITL.decision(:approve)], opts)
"cus_ada/A-1001" = result.refund_flag
```

## Async subagents

Async delegation starts work through a client or remote service. It exposes
five tools: start, check, update, cancel and list async tasks. Task IDs and
statuses live in `async_tasks`; reuse the same saved thread to find them.
An interrupted remote task is not final, while completed/error/timeout/cancelled
states are final. Refresh status before reporting completion.

Configure `AsyncSpec` with a `client:` implementing `Agent.Protocol.Client`,
or a `url:` plus headers for `ReqClient`. The HTTP contract is:

| Operation | Endpoint |
| --- | --- |
| Start | `POST /runs` |
| Check | `GET /runs/:task_id` |
| Update | `POST /runs/:task_id/input` |
| Cancel | `POST /runs/:task_id/cancel` |

Client callbacks receive parent thread/run/tool-call and trace identifiers.
Treat them as correlation data, not proof of authorization. The remote service
owns scheduling, persistence and cancellation. The complete
[async server example](https://github.com/caudena/beam_weaver/blob/master/examples/deepagents/async_subagent_server.exs)
shows a runnable service integration rather than an invented hosted URL.

This complete local protocol client runs a small audit in a background task. It computes duplicate order IDs from the stated sample records; it does not pretend to contact a hosted audit service. The parent model makes real OpenAI calls to start and check the task:

```elixir
defmodule MyApp.LocalAuditClient do
  @behaviour BeamWeaver.Agent.Protocol.Client

  @impl true
  def start_task(_spec, _payload, _opts) do
    id = "audit-#{System.unique_integer([:positive])}"
    running = %{"thread_id" => id, "status" => "running"}
    Agent.update(MyApp.AuditTasks, &Map.put(&1, id, running))

    {:ok, _} =
      Task.start(fn ->
        rows = [%{order_id: "A-1001"}, %{order_id: "A-1002"}, %{order_id: "A-1001"}]

        duplicates =
          rows |> Enum.frequencies_by(& &1.order_id) |> Enum.filter(fn {_, n} -> n > 1 end) |> Enum.map(&elem(&1, 0))

        Agent.update(MyApp.AuditTasks, fn tasks ->
          Map.update!(tasks, id, fn task ->
            if task["status"] == "cancelled",
              do: task,
              else:
                Map.merge(task, %{
                  "status" => "success",
                  "result" => "Duplicate order IDs: " <> Enum.join(duplicates, ", ")
                })
          end)
        end)
      end)

    {:ok, running}
  end

  @impl true
  def check_task(_spec, id, _opts), do: Agent.get(MyApp.AuditTasks, &Map.fetch(&1, id))

  @impl true
  def update_task(_spec, id, message, _opts) do
    Agent.update(MyApp.AuditTasks, &Map.update!(&1, id, fn task -> Map.put(task, "reviewer_note", message) end))
    check_task(nil, id, [])
  end

  @impl true
  def cancel_task(_spec, id, _opts) do
    Agent.update(MyApp.AuditTasks, &Map.update!(&1, id, fn task -> Map.put(task, "status", "cancelled") end))
    check_task(nil, id, [])
  end
end

defmodule MyApp.AsyncAuditAgent do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000

  system_prompt "When asked to start, call start_async_task once and return its ID without polling. When asked to check, call check_async_task with the exact provided ID and report the result."

  async_subagents do
    async_subagent "refund_auditor",
      description: "Audits sample refunds for duplicate order IDs.",
      graph_id: "refund_auditor",
      client: MyApp.LocalAuditClient
  end
end

{:ok, tasks} = Agent.start_link(fn -> %{} end, name: MyApp.AuditTasks)

try do
  opts = [checkpointer: BeamWeaver.Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => "async-audit"}}]

  {:ok, started} =
    MyApp.AsyncAuditAgent.invoke(
      %{messages: ["Start a refund_auditor audit of the sample refunds. Do not check yet."]},
      opts
    )

  [task_id] = Map.keys(started.async_tasks)

  {:ok, checked} =
    MyApp.AsyncAuditAgent.invoke(%{messages: ["Check audit #{task_id} and report the actual result."]}, opts)

  true = checked.async_tasks[task_id].result =~ "A-1001"
  true = Enum.any?(checked.messages, &(&1.role == :tool and &1.name == "check_async_task"))
after
  Agent.stop(tasks)
end
```

## Application-owned child admission

`BeamWeaver.Agent.Subagent.Host` is a separate boundary for an application
that owns child scheduling and persistence. A closed `Proposal` describes
task type, text, foreground/background mode and correlation ID; it grants no
authority. The host validates admission and returns an opaque `Handle`.

Result lookup returns a bounded typed result, an error, or the identical
background handle while pending. Foreground work cannot remain pending, and
background work cannot request synchronous parent input. Outcomes distinguish
completion, failure, cancellation, blocked capability and needed input. The
application owns authorization, recovery and evidence references.

This foreground host enforces an application-supplied allowlist, executes a real model call, and stores the result behind an opaque handle. Replace the in-memory result map with your durable scheduler/store when deploying:

```elixir
defmodule MyApp.ForegroundHost do
  @behaviour BeamWeaver.Agent.Subagent.Host
  alias BeamWeaver.Agent.Subagent.Host.{Handle, Result}
  defstruct [:model, :results]

  @impl true
  def admit_child(host, proposal, context) do
    if proposal.type in context.allowed_types do
      with {:ok, reply} <- BeamWeaver.Core.ChatModel.invoke(host.model, proposal.task) do
        id = "child-#{System.unique_integer([:positive])}"
        result = %Result{handle_id: id, outcome: :completed, content: BeamWeaver.Core.Message.text(reply)}
        Agent.update(host.results, &Map.put(&1, id, result))
        {:ok, %Handle{id: id, mode: proposal.mode}}
      end
    else
      {:error, :unauthorized_child_type}
    end
  end

  @impl true
  def child_result(host, handle, _context), do: Agent.get(host.results, &Map.fetch(&1, handle.id))
end

alias BeamWeaver.Agent.Subagent.Host
{:ok, results} = Agent.start_link(fn -> %{} end)

try do
  host =
    struct!(MyApp.ForegroundHost,
      results: results,
      model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)
    )

  proposal = %Host.Proposal{
    type: "calculation",
    task: "Calculate 19 + 23 briefly.",
    mode: :foreground,
    correlation_id: "request-1"
  }

  context = %{allowed_types: ["calculation"]}
  {:ok, handle} = Host.admit(host, proposal, context)
  {:ok, result} = Host.result(host, handle, context)
  :completed = result.outcome
  true = result.content =~ "42"
after
  Agent.stop(results)
end
```

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Parent does not delegate | Distinct descriptions and explicit delegation instructions |
| Child lacks facts | Include them in the task or deliberately inherit messages |
| Child has unexpected tools | Specify `tools: []` or an explicit set |
| Missing workspace or skills | Child declarations or requested base middleware |
| Captured answer seems stale | Deduplication and thread identity |
| Missing checkpointer | A nested review requires saved continuation |
| Unknown async task | Full task ID and original thread |
