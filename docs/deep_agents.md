# Compose a Deep Agent

A deep agent is an ordinary agent with a workspace and capabilities for
longer tasks: planning, files, skills, memory and delegation. There is no
separate runtime or hidden orchestration service. Add only what the task needs.

Complete [Installation](installation.md). This example makes real OpenAI
calls, reads supplied policy data and creates a note in thread state.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Plan, read and write

```elixir
defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 1_024, timeout: 60_000

  system_prompt """
  For a support investigation: write a task list, read the supplied policy,
  write a factual note, then mark the tasks completed. Do not claim a refund
  was paid. Use only the policy and customer facts provided.
  """

  filesystem BeamWeaver.Filesystem.State.new()
  middleware [BeamWeaver.Agent.Middleware.TodoList]
  recursion_limit 30
  run_timeout 180_000
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "investigation-A-1001"}}]

{:ok, result} =
  MyApp.SupportResearcher.invoke(
    %{
      messages: [
        "Investigate broken mug order A-1001. Read /policies/refunds.md and save a note at /notes/A-1001.md. Complete your task list."
      ],
      files: %{"/policies/refunds.md" => "Damaged goods are eligible for a full refund after staff approval.\n"}
    },
    opts
  )

true = result.todos != []
true = Enum.all?(result.todos, &(&1.status == "completed"))
note = result.files["/notes/A-1001.md"].content
true = note =~ "A-1001"
true = String.downcase(note) =~ "refund"
true = Enum.any?(result.messages, &(&1.role == :tool and &1.name == "read_file"))
```

Inspect artifacts and state, not just the final answer. A model can say it
saved a note without doing so; the checks above read the actual file and plan.
The policy is a local example dataset, not a live business policy service.

## One agent, more capabilities

| Capability | Declaration or middleware | Guide |
| --- | --- | --- |
| Task list | `TodoList` | Below |
| File tools | `filesystem` | [Filesystem](filesystem.md) |
| Path rules | `filesystem_permissions` | [Permissions](filesystem.md#permissions) |
| On-demand procedures | `skills` | [Skills](skills.md) |
| Short persistent instructions | `memory` | [Memory Files](memory_files.md) |
| Delegated tasks | `subagents`, `async_subagents` | [Subagents](subagents.md) |
| Context policy | `compact_conversation`, `overflow_recovery` | [Context Management](context_management.md) |
| Commands | An executable filesystem or `ShellTool` | [Sandboxes](sandboxes.md) |
| Approval | `interrupt_on` | [Human Review](human_in_the_loop.md) |
| Model tuning | `capability_profile` | [Capability Profiles](profiles.md) |

Each capability adds tools, state or prompt instructions. More capabilities
mean more model-visible choices and more possible side effects.

## Plan with a task list

`TodoList` exposes `write_todos`. Each call replaces the entire list; items
have content and pending/in_progress/completed status. Concurrent task-list
writes in one model turn are rejected so the model can submit one coherent
update. The default state key is `todos`.

Options include `state_key:`, `tool_name:`, `tool_description:` and
`system_prompt:`. A plan is model-maintained progress, not independent evidence
that each task happened. Verify the promised outputs separately.

Use a different state key when your application calls the list a plan. The agent must write the completed task:

```elixir
defmodule MyApp.PlanningAgent do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Record the requested tasks with write_todos before replying."
  middleware [{BeamWeaver.Agent.Middleware.TodoList, state_key: :plan}]
end

{:ok, plan_result} = MyApp.PlanningAgent.invoke(%{messages: ["Record one completed task: Read supplied policy."]})
[%{content: content, status: "completed"}] = plan_result.plan
"Read supplied policy" = String.trim_trailing(content, ".")
```

## Keep the plan and files between calls

```elixir
{:ok, snapshot} = MyApp.SupportResearcher.get_state(opts)
true = snapshot.values.files["/notes/A-1001.md"].content == note
true = snapshot.values.todos == result.todos
```

State-backed plans/files are per-thread and follow checkpoint durability.
This example's ETS data disappears with its owner process. Shared data needs
a persistent filesystem or memory-store namespace; restart recovery needs
a database saver. See [Storage](storage.md).

## How capabilities combine

Capability middleware is assembled before explicitly listed middleware.
The declared order covers skills, filesystem, subagents, compaction/overflow,
async delegation, tool selection, prompt caching, memory and human review.
An explicit middleware entry usually replaces the same capability module;
missing options can inherit declaration settings. Tool-selection exclusions
are cumulative rather than replaced.

`DynamicPrompt` supplies the base prompt before capability sections are added.
When you customize prompt or middleware assembly, inspect the actual request
and ensure required policy sections still reach the model.

Skills and memory can read state files without a filesystem declaration, but
the model needs file tools to open skills or edit notes. Declare a filesystem
when those actions are part of the task.

## Context management

Offload large tool results into files, retain a recent conversation window and
summarize older material. Use overflow recovery as a fallback when a provider
still rejects an oversized request. Keep source material retrievable: a
summary is not a lossless archive. [Context Management](context_management.md)
shows an actual compaction trigger.

## Code execution

An executable backend adds `execute`. LocalShell and local sandboxes run as
your application user; file-tool permissions do not constrain shell commands.
Use a suitable isolated runtime and explicit command policy for the work you
allow. [Sandboxes](sandboxes.md) covers lifecycle and boundary differences.

## Human review

Review file writes, commands or domain actions with `interrupt_on` when the
application requires approval. Pauses need checkpoint storage. Nested review
propagates to the parent, which resumes through the same thread. Approval
must be tied to the actual proposed arguments, not a narrative plan.

## Subagents

Delegate a bounded question with a clear output contract. A synchronous child
returns a final result to the parent; remote async tasks require explicit
status/result handling. Include the relevant source data in the task and
check the result before using it. [Subagents](subagents.md) explains shared
files, context, captured outputs and review inheritance.

## Watch a long run

Stream tool events and graph updates to show work in progress. Plan updates
come through state changes; file operations and delegation have tool events.
A completed task-list item does not guarantee the workflow completed.
Handle terminal errors and interrupts, and use [Tracing](tracing.md) to inspect
provider attempts, tools and child runs afterward.

Collect a new investigation stream once and inspect real tool progress and final saved artifacts:

```elixir
stream_opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "streamed-investigation"}}, live: true]

{:ok, stream} =
  MyApp.SupportResearcher.stream_events(
    %{
      messages: [
        "Investigate broken mug A-1002. Read /policies/refunds.md, write /notes/A-1002.md, and complete your task list."
      ],
      files: %{"/policies/refunds.md" => "Damaged goods qualify for a full refund after staff approval."}
    },
    stream_opts
  )

events = Enum.to_list(stream)
true = Enum.any?(events, &match?(%{event: %BeamWeaver.Stream.Events.ToolFinish{}}, &1))
{:ok, saved} = MyApp.SupportResearcher.get_state(Keyword.delete(stream_opts, :live))
true = saved.values.files["/notes/A-1002.md"].content =~ "A-1002"
```

## Test a deep agent

For application tests, script model actions and assert actual files, task
state, delegated outputs and tool arguments. Keep representative live checks
for model behavior. [Testing](testing.md) covers deterministic setup;
[Examples](examples.md) lists complete larger projects.
