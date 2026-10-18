# Deep Agents

A deep agent is an ordinary agent with more capabilities switched on: a task
list to plan with, files for notes and large results, skills, memory files,
and subagents for self-contained work. Use one for long tasks with many
steps, such as researching a customer's problem across orders and policies
before answering.

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts),
    do: {:ok, "Order #{order_id} was delivered on Monday. The customer reported a broken mug."}
end

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("write_todos", %{
        "todos" => [
          %{"content" => "Look up order A-1001", "status" => "in_progress"},
          %{"content" => "Write notes for the refunds team", "status" => "pending"}
        ]
      }),
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      FakeChatModel.tool_calls([
        {"write_file",
         %{"file_path" => "/notes/A-1001.md", "content" => "Delivered Monday, mug broken. Offer a full refund.\n"}},
        {"write_todos",
         %{
           "todos" => [
             %{"content" => "Look up order A-1001", "status" => "completed"},
             %{"content" => "Write notes for the refunds team", "status" => "completed"}
           ]
         }}
      ]),
      "Order A-1001 arrived with a broken mug, so Ada gets a full refund. My notes are in /notes/A-1001.md."
    ]

  system_prompt "You are Acme's support researcher. Plan with write_todos, keep notes in /notes, then answer."
  tools [MyApp.Tools.LookupOrder]
  middleware [BeamWeaver.Agent.Middleware.TodoList]
  filesystem BeamWeaver.Filesystem.State.new()
end

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["Ada's order A-1001 arrived broken. What can we offer?"]})

result.todos
#=> [
#     %{content: "Look up order A-1001", status: "completed"},
#     %{content: "Write notes for the refunds team", status: "completed"}
#   ]
```

The scripted model writes a two-step plan with `write_todos`, looks the order
up, saves a note with `write_file` while it marks both steps done, and
answers. The plan and the files are part of the result, next to the messages:

```elixir
result.files["/notes/A-1001.md"].content
#=> "Delivered Monday, mug broken. Offer a full refund.\n"
```

`TodoList` gave the agent the `write_todos` tool and keeps the plan in
`todos`. `filesystem` gave it file tools, and `BeamWeaver.Filesystem.State`
keeps the files in the thread's state under `files`. With a checkpointer,
both carry over to the next call on the same thread.

## One agent, more capabilities

There is no separate deep-agent type. `MyApp.SupportResearcher` is an agent
module like any other: it runs with `invoke/2`, streams, pauses for review and
saves checkpoints. Each capability is one declaration, or one middleware, that
adds tools and keys in the state, and some add a section of the system prompt:

| Capability | Turn it on with | The model gets | Guide |
| --- | --- | --- | --- |
| Planning | `middleware [BeamWeaver.Agent.Middleware.TodoList]` | `write_todos` | [below](#plan-with-a-task-list) |
| Files | `filesystem BeamWeaver.Filesystem.State.new()` | `ls`, `read_file`, `write_file`, `edit_file`, `glob`, `grep` | [Filesystem](filesystem.md) |
| File rules | `filesystem_permissions [...]` | an error for paths it may not use | [Filesystem](filesystem.md) |
| Skills | `skills ["/skills"]` | a list of skills to read when they apply | [Skills](skills.md) |
| Memory files | `memory ["/AGENTS.md"]` | the files in its system prompt | [Memory Files](memory_files.md) |
| Subagents | `subagents do subagent MyApp.PolicyExpert end` | `task` | [Subagents](subagents.md) |
| Background subagents | `async_subagents [...]` | `start_async_task` and four more | [Subagents](subagents.md) |
| Context management | `compact_conversation true`, `overflow_recovery true` | `compact_conversation` | [Context Management](context_management.md) |
| Code execution | a filesystem that runs commands | `execute` | [Sandboxes](sandboxes.md) |
| Human review | `interrupt_on %{"issue_refund" => true}` | a pause before those tools run | [Human-in-the-Loop](human_in_the_loop.md) |
| Per-model tuning | a capability profile | depends on the profile | [Capability Profiles](profiles.md) |

Switch on only what a task needs: the model reads every capability's tools,
and the prompt sections some of them add, on every call. The next guides take
the capabilities in turn: [Filesystem](filesystem.md), [Skills](skills.md),
[Subagents](subagents.md), [Sandboxes](sandboxes.md) and
[Capability Profiles](profiles.md).

## Plan with a task list

`BeamWeaver.Agent.Middleware.TodoList` gives the model the `write_todos` tool
and tells it to plan tasks of three or more steps. Each call replaces the
whole list. An item has `content` and a `status` of `"pending"`,
`"in_progress"` or `"completed"`; any other status is rejected, and the model
gets the error back.

The list lives in the state under `todos`, so it is in the result, in every
checkpoint, and in stream events, where a UI can show progress (see
[Watch a long run](#watch-a-long-run)). The model may write the list once per
turn: when it calls `write_todos` twice at once, both calls fail with an error
that asks for a single call.

`TodoList` takes these options:

| Option | Default | What it changes |
| --- | --- | --- |
| `state_key` | `:todos` | the state key that holds the list |
| `system_prompt` | when and how to plan | the section added to the system prompt |
| `tool_description` | how to use the statuses | the description of the tool |
| `tool_name` | `"write_todos"` | the tool's name, which the default `system_prompt` and errors use |

```elixir
model "fake:chat"
middleware [{BeamWeaver.Agent.Middleware.TodoList, state_key: :plan}]
```

A subagent keeps its own list. The parent never sees it, only the subagent's
answer.

## Keep the plan and files between calls

With a checkpointer and a thread id, the plan and the files are saved with the
thread, so the next call on the thread starts with them. `get_state/1` reads
them without running the agent:

```elixir
saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, _result} =
  MyApp.SupportResearcher.invoke(%{messages: ["Ada's order A-1001 arrived broken. What can we offer?"]}, opts)

{:ok, snapshot} = MyApp.SupportResearcher.get_state(opts)
{length(snapshot.values.todos), Map.keys(snapshot.values.files)}
#=> {2, ["/notes/A-1001.md"]}
```

In production, `Checkpoint.Ecto` keeps the thread, its plan and its files
across restarts (see [Checkpoints and Time Travel](checkpoints.md)). Files in
`Filesystem.State` belong to one thread. For files that every thread should
see, such as a team's playbook or a customer's history, keep them in a
directory or a memory store instead (see [Filesystem](filesystem.md)).

## How capabilities combine

Each declaration adds middleware. BeamWeaver adds it in this order, ahead of
the middleware you list yourself:

1. `skills`
2. `filesystem`, with its `filesystem_permissions`
3. `subagents`
4. `compact_conversation`, then `overflow_recovery`
5. `async_subagents`
6. `exclude_tools` and `tool_descriptions`
7. `prompt_caching`
8. `memory`
9. `interrupt_on`
10. your `middleware` list, in its own order

The order shows in the system prompt. Your `system_prompt` comes first, then
the sections of the capabilities that add one, in the order above, then the
sections of your own middleware. The agent at the top of this page sends its
prompt, the file tools section, then the `write_todos` section. A
`BeamWeaver.Agent.Middleware.DynamicPrompt` in your list takes the place of
`system_prompt`, and the sections still follow it. The model's tools come in
the same order, followed by the tools you declared.

Two rules follow from how the middleware is put together:

- **Your entry wins.** If your `middleware` list names a module that a
  declaration would add, such as `BeamWeaver.Agent.Middleware.Filesystem`,
  BeamWeaver drops the declared one and keeps yours. Options you leave out
  of a `Filesystem`, `Skills`, `Memory`, `CompactConversation` or
  `OverflowRecovery` entry written as `{module, opts}` (or the bare module)
  come from the declarations: its `backend` is the declared `filesystem`,
  and a `Filesystem` entry also gets `filesystem_permissions` (see
  [Filesystem](filesystem.md#change-the-large-result-limits)). The
  `ToolSelection` that `exclude_tools` adds is the exception: it runs before a
  `ToolSelection` of yours, and both apply.
- **Some capabilities read files.** `skills`, `memory`,
  `compact_conversation` and `overflow_recovery` read and write through the
  agent's `filesystem`. Without one they use the thread's state, and the agent
  gets no file tools, so it can't open a skill or edit a memory file. Declare
  a `filesystem` with them.

## Context management

A long run collects more messages and tool results than a context window
holds. With a `filesystem`, tool results over about 20,000 tokens are saved to
files under `/large_tool_results/` and the model reads them back a page at a
time. `compact_conversation true` summarizes older history once the thread
gets long, and gives the model a `compact_conversation` tool to do it between
tasks. `overflow_recovery true` retries a request that a provider rejects as
too long. See [Context Management](context_management.md).

```elixir
model "anthropic:claude-sonnet-4-6"
filesystem BeamWeaver.Filesystem.State.new()
compact_conversation true
overflow_recovery true
```

## Code execution

When the filesystem can run commands, the agent also gets an `execute` tool
that runs a shell command and returns its output and exit code. `BeamWeaver.Filesystem.LocalShell`
runs commands on your machine, for development only;
`BeamWeaver.Filesystem.Sandbox` runs them in a sandbox, such as a Docker
container. File permissions don't limit what a command does, so pause before
commands that matter with `interrupt_on %{"execute" => true}`. To allow only
a short list of commands instead of a full shell, use the `ShellTool`
middleware, which requires a policy ([Sandboxes](sandboxes.md#shell-tool-and-policies)).

## Human review

`interrupt_on` pauses the run before the tools you name, including deep-agent
tools such as `write_file`, `execute` and `task`, so a person can approve,
edit or reject the call. The paused run waits in the checkpointer and
continues with `resume_review/2`:

```elixir
model "anthropic:claude-sonnet-4-6"
filesystem BeamWeaver.Filesystem.State.new()
interrupt_on %{"issue_refund" => true, "write_file" => true}
```

A pause inside a subagent pauses the parent too: the parent returns the
subagent's review, and resuming the parent resumes the subagent
([Subagents](subagents.md#human-review)). Subagents use the parent's
`interrupt_on` rules unless they set their own. See
[Human-in-the-Loop](human_in_the_loop.md).

## Subagents

`subagents` gives the agent a `task` tool. The model calls it with a
description of the work and the name of a subagent, which runs in its own
context window and returns only its final answer. The parent's thread grows
by one tool result instead of every search and file read the work needed. A
`general-purpose` subagent, a copy of the parent with its tools, files and
skills but no task list, is available too unless you turn it off. For work
that outlasts a request, `async_subagents` starts a task on another agent
server and gives the model tools to check on it, update it or cancel it. See
[Subagents](subagents.md).

```elixir
model "anthropic:claude-sonnet-4-6"

subagents do
  subagent MyApp.PolicyExpert
end
```

## Watch a long run

A deep agent can work for minutes. `stream_events/2` reports each step while
it happens: tool calls, file writes, and every new version of the plan. The
plan arrives in the state updates of the `tools` step:

```elixir
alias BeamWeaver.Stream.Events

{:ok, events} =
  MyApp.SupportResearcher.stream_events(%{messages: ["Ada's order A-1001 arrived broken. What can we offer?"]},
    live: true
  )

for %{event: %Events.GraphUpdate{update: %{"tools" => %{todos: todos}}}} <- events,
    do: Enum.map(todos, & &1.status)
#=> [["in_progress", "pending"], ["completed", "completed"]]
```

A UI can redraw a checklist from each update and show `ToolStart` events as
"Reading /skills/refund-policy/SKILL.md…". [Streaming](streaming.md) lists
every event. To look back at a run, with each model call, tool call and
subagent run in one tree, use [Tracing](tracing.md).

## Use a real model

Swap the scripted model for a provider model and drop the script: the model
now decides when to plan, which files to write and when to delegate. This
version also keeps its files in a directory, reads skills and a memory file,
compacts long threads, and can ask a policy expert:

```elixir
defmodule MyApp.PolicyExpert do
  use BeamWeaver.Agent

  name "policy_expert"
  description "Answers questions about Acme's refund and return policies."
  model "anthropic:claude-haiku-4-5"
  system_prompt "You are Acme's policy expert. Answer in two sentences and name the rule you applied."
end

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  model "anthropic:claude-sonnet-4-6", timeout: 120_000
  system_prompt "You are Acme's support researcher. Plan with write_todos, keep notes in /notes, then answer."

  tools [MyApp.Tools.LookupOrder]
  middleware [BeamWeaver.Agent.Middleware.TodoList]
  filesystem BeamWeaver.Filesystem.Local.new(root: "/var/lib/acme/support_researcher")
  filesystem_permissions [BeamWeaver.Filesystem.Permission.new(operations: [:write], paths: ["/skills/**"], mode: :deny)]
  skills ["/skills"]
  memory ["/AGENTS.md"]
  compact_conversation true

  subagents do
    subagent MyApp.PolicyExpert
  end
end

opts = [
  checkpointer: BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo),
  config: %{"configurable" => %{"thread_id" => "ticket-42"}}
]

MyApp.SupportResearcher.invoke(%{messages: ["Ada's order A-1001 arrived broken. What can we offer?"]}, opts)
```

The agent sees the directory as `/`: its notes land in
`/var/lib/acme/support_researcher/notes`, its memory is `AGENTS.md` there, and
the permission rule lets it read the skills in `skills/` but not change them.
A deep agent makes many model calls per run, so give slow models a generous
`timeout` and cap runaway loops with `recursion_limit`, or with the
`ModelCallLimit` middleware and a `run_limit` that leaves room for the work
([Built-in Middleware](builtin_middleware.md#modelcalllimit)).

## Test a deep agent

Test a deep agent the way this page runs one: script the fake model's tool
calls, then assert on what the agent did, such as `result.todos`,
`result.files` and the tool messages, rather than on the wording of the
built-in instructions, which can change between versions. Seed the files a
test needs, such as skills or a memory file, with `files:` in the input. See
[Testing](testing.md).

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): the agent DSL, including the capability declarations
- [`BeamWeaver.Agent.Middleware.TodoList`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.TodoList.html): the `write_todos` planning tool
- [`BeamWeaver.Tools.Todo`](https://hexdocs.pm/beam_weaver/BeamWeaver.Tools.Todo.html): the tool behind `write_todos`
- [`BeamWeaver.Agent.Middleware.Filesystem`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Filesystem.html): the file tools and large-result offloading
- [`BeamWeaver.Agent.Middleware.Skills`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Skills.html): the skills list in the system prompt
- [`BeamWeaver.Agent.Middleware.Memory`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Memory.html): memory files in the system prompt
- [`BeamWeaver.Agent.Middleware.Subagents`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Subagents.html): the `task` tool
- [`BeamWeaver.Filesystem`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.html): the filesystem behaviour and its backends
