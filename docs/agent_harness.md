# Agent Harness Capabilities

Official Deep Agents describes an agent harness as a bundle of capabilities for
long-running agents: planning, a virtual filesystem, permissions, subagents,
context management, code execution, human review, skills, memory files, and
profiles. BeamWeaver integrates those capabilities into normal agents instead
of exposing a separate `create_deep_agent` API.

Use `use BeamWeaver.Agent` or `BeamWeaver.Agent.build/1`, then enable the
capabilities you need through agent fields and middleware. The same graph
runtime, checkpointers, stores, interrupts, streaming, and middleware pipeline
apply to both small agents and harnessed long-running agents.

{% hint style="info" %}
**Integrated Surface**

There is no second DeepAgents agent type in BeamWeaver. A "deep" agent is a
regular `BeamWeaver.Agent` with additional middleware, tools, filesystems,
subagents, and context-management options.
{% endhint %}

## Capability Map

| Harness capability | BeamWeaver surface |
| --- | --- |
| Planning | `BeamWeaver.Agent.Middleware.TodoList` and `BeamWeaver.Tools.Todo` |
| Virtual filesystem | `filesystem` / `:filesystem`, `BeamWeaver.Agent.Middleware.Filesystem`, `BeamWeaver.Tools.Filesystem` |
| Filesystem permissions | `filesystem_permissions` / `:filesystem_permissions`, `BeamWeaver.Filesystem.Permission` |
| Task delegation | `subagents`, `async_subagents`, `BeamWeaver.Agent.Middleware.Subagents`, `BeamWeaver.Agent.Middleware.AsyncSubagents` |
| Context management | `compact_conversation`, `overflow_recovery`, `prompt_caching`, `BeamWeaver.Agent.Middleware.Summarization` |
| Code execution | Executable filesystem backends, `execute`, and `BeamWeaver.Agent.Middleware.ShellTool` |
| Human review | `interrupt_on` and `BeamWeaver.Agent.Middleware.HumanInTheLoop` |
| Skills | `skills` and `BeamWeaver.Agent.Middleware.Skills` |
| Memory files | `memory` and `BeamWeaver.Agent.Middleware.Memory` |
| Profiles | `BeamWeaver.Agent.CapabilityProfile` and `BeamWeaver.Agent.CapabilityProfileConfig` |

## Build A Harnessed Agent

Runtime construction:

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Agent.Middleware
alias BeamWeaver.Agent.Subagent
alias BeamWeaver.Core.Message
alias BeamWeaver.Filesystem
alias BeamWeaver.Filesystem.Permission

{:ok, agent} =
  Agent.build(
    name: "engineering_agent",
    model: BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6"),
    tools: [MyApp.Tools.SearchDocs],
    filesystem: Filesystem.State.new(),
    filesystem_permissions: [
      Permission.new(
        operations: [:read, :write],
        paths: ["/workspace/.env", "/workspace/secrets/**"],
        mode: :deny
      ),
      Permission.new(operations: [:read, :write], paths: ["/workspace/**"], mode: :allow)
    ],
    skills: ["/skills"],
    memory: ["/AGENTS.md"],
    subagents: [
      Subagent.Spec.new(
        name: "researcher",
        description: "Search and summarize project evidence.",
        system_prompt: "Return only sourced findings."
      )
    ],
    compact_conversation: true,
    overflow_recovery: true,
    prompt_caching: true,
    interrupt_on: %{"edit_file" => true},
    middleware: [
      {Middleware.TodoList, tool_name: "write_todos"}
    ]
  )

Agent.invoke(agent, %{messages: [Message.user("Investigate the failing tests.")]})
```

Module-defined agents use the same fields:

```elixir
defmodule MyApp.EngineeringAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Subagent
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Permission

  model BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6")
  tools [MyApp.Tools.SearchDocs]

  filesystem Filesystem.State.new()

  filesystem_permissions [
    Permission.new(operations: [:read, :write], paths: ["/workspace/.env"], mode: :deny),
    Permission.new(operations: [:read, :write], paths: ["/workspace/**"], mode: :allow)
  ]

  skills ["/skills"]
  memory ["/AGENTS.md"]

  subagents [
    Subagent.Spec.new(
      name: "researcher",
      description: "Search and summarize project evidence.",
      system_prompt: "Return only sourced findings."
    )
  ]

  compact_conversation true
  overflow_recovery true
  interrupt_on %{"edit_file" => true}

  middleware [
    {Middleware.TodoList, tool_name: "write_todos"}
  ]
end
```

## Planning

Add `BeamWeaver.Agent.Middleware.TodoList` when the model should keep an
explicit task list. The middleware contributes a TODO tool, stores the list in
agent state, and prevents multiple TODO writes from one model response.

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.TodoList,
   state_key: :todos,
   tool_name: "write_todos"}
]
```

The default top-level tool name is `todo`. Set `tool_name: "write_todos"` when
you want the official Deep Agents name. Subagents created through
`BeamWeaver.Agent.Middleware.Subagents` already receive a `write_todos` tool.

## Virtual Filesystem

Set `filesystem` on an agent to add `BeamWeaver.Agent.Middleware.Filesystem`.
It contributes these tools:

| Tool | Description |
| --- | --- |
| `ls` | List virtual files and directories. |
| `read_file` | Read a file by absolute virtual path with optional `offset` and `limit` line pagination. |
| `write_file` | Create a new file. |
| `edit_file` | Perform exact string replacement in a UTF-8 text file. |
| `glob` | Find files by glob pattern. |
| `grep` | Search UTF-8 file contents for a literal string. |
| `execute` | Run shell commands when the backend implements `BeamWeaver.Filesystem.Executable`. |

Filesystem backends are virtual and POSIX-style from the agent's perspective.
Current built-in backends include:

| Backend | Use |
| --- | --- |
| `BeamWeaver.Filesystem.State` | Thread-scoped files stored in graph state. |
| `BeamWeaver.Filesystem.Store` | Files persisted in a `BeamWeaver.Memory.Store` namespace. |
| `BeamWeaver.Filesystem.Local` | Trusted local development or CI root. |
| `BeamWeaver.Filesystem.LocalShell` | Trusted local root plus shell execution. |
| `BeamWeaver.Filesystem.Composite` | Route virtual path prefixes to different backends. |
| `BeamWeaver.Filesystem.Sandbox` | Adapt a `BeamWeaver.Sandbox` backend into the filesystem protocol. |

`read_file` returns text directly for UTF-8 files. Binary files are stored as
base64 `BeamWeaver.Filesystem.FileData`; filesystem tools return a text notice
plus a base64 content block for model consumption, while custom tools can use
`download_files/2` for raw bytes.

For routing, persistence, local disk, sandbox, and custom filesystem details,
see [Filesystem](filesystem.md).

## Filesystem Permissions

Use `BeamWeaver.Filesystem.Permission` rules to restrict the model-visible
filesystem tools:

```elixir
filesystem_permissions [
  Permission.new(operations: [:read, :write], paths: ["/workspace/.env"], mode: :deny),
  Permission.new(operations: [:read, :write], paths: ["/workspace/**"], mode: :allow)
]
```

Rules are evaluated in list order. The first matching rule wins. If no rule
matches, access is allowed. Permissions apply to `ls`, `read_file`,
`write_file`, `edit_file`, `glob`, and `grep`. They also post-filter listed and
searched paths so denied files do not appear in model-visible results.

For focused examples including read-only memory, subagent overrides, and
composite filesystem caveats, see [Filesystem Permissions](permissions.md).

{% hint style="warning" %}
**Execution Is A Separate Security Boundary**

Filesystem permissions do not sandbox arbitrary shell commands. If the agent has
an `execute` or shell tool, enforce command safety with the backend, container,
runtime, policy hooks, or `BeamWeaver.Agent.Middleware.ShellTool` policy.
{% endhint %}

## Task Delegation

Pass `subagents` to add the `task` tool. Each task launches an ephemeral
subagent with its own message context and returns one final result to the
parent:

```elixir
alias BeamWeaver.Agent.Subagent

subagents [
  Subagent.Spec.new(
    name: "researcher",
    description: "Collect evidence without changing files.",
    system_prompt: "Return concise findings with file paths."
  ),
  Subagent.Spec.new(
    name: "editor",
    description: "Apply small scoped edits.",
    system_prompt: "Edit only files mentioned by the task."
  )
]
```

Synchronous subagents inherit useful harness pieces from the parent: filesystem
backend, filesystem permissions, skills, HITL configuration, summarization, and
conversation compaction. They receive a fresh `messages` list so their working
context does not pollute the parent conversation, but non-private state keys can
be merged back into the parent when the task completes.

Use `async_subagents` or `BeamWeaver.Agent.Subagent.AsyncSpec` entries when the
work should run on a remote Agent Protocol server:

```elixir
async_subagents [
  BeamWeaver.Agent.Subagent.AsyncSpec.new(
    name: "remote_research",
    description: "Background research worker.",
    graph_id: "research_graph",
    url: "https://agents.example.com"
  )
]
```

Async subagents expose `start_async_task`, `check_async_task`,
`update_async_task`, `cancel_async_task`, and `list_async_tasks`.

For full delegation details, see [Subagents](subagents.md) and
[Async Subagents](async_subagents.md).

## Context And Token Management

BeamWeaver combines several context controls:

| Control | BeamWeaver surface |
| --- | --- |
| Summarize older messages before model calls | `BeamWeaver.Agent.Middleware.Summarization` |
| Give the model a manual compaction tool | `compact_conversation: true` or `compact_conversation true` |
| Retry context overflow with clipped/offloaded tool results | `overflow_recovery: true` or `overflow_recovery true` |
| Save oversized tool results to the filesystem | `BeamWeaver.Agent.Middleware.Filesystem` |
| Save oversized user messages to conversation-history files | `BeamWeaver.Agent.Middleware.Filesystem` |
| Mark static Anthropic system prompts for cache control | `prompt_caching: true` or `prompt_caching true` |
| Isolate heavy subtasks | `subagents` and `async_subagents` |

`compact_conversation` adds a `compact_conversation` tool that summarizes older
messages, writes the full conversation slice to the filesystem, and replaces the
old messages with a summary on the next model turn. `overflow_recovery` is a
defensive retry path for provider context-limit errors.

## Code Execution

BeamWeaver exposes shell execution through executable filesystem backends and
through the prebuilt shell middleware.

Use a sandbox-backed filesystem when execution should be part of the virtual
filesystem harness:

```elixir
filesystem BeamWeaver.Filesystem.Sandbox.new(
  sandbox: BeamWeaver.Sandbox.local(root: "/tmp/my-agent-workspace")
)
```

For container isolation, use `BeamWeaver.Sandbox.Docker` and select a hardened
runtime for production deployments when available:

```elixir
filesystem BeamWeaver.Filesystem.Sandbox.new(
  sandbox:
    BeamWeaver.Sandbox.Docker.new(
      image: "docker.io/library/python:3.11-slim",
      runtime: "runsc"
    )
)
```

For a narrower command surface, add `BeamWeaver.Agent.Middleware.ShellTool`
with an allow-list policy instead of exposing a general `execute` tool.

See [Sandboxes](sandboxes.md) for lifecycle, file transfer, provider adapter,
and security guidance.

## Human-In-The-Loop

Set `interrupt_on` to pause before selected tools execute:

```elixir
interrupt_on %{
  "edit_file" => true,
  "send_email" => %{allowed_decisions: [:approve, :edit, :reject]}
}
```

`true` allows approve, edit, reject, or respond decisions. A map can restrict
the allowed decisions and optionally provide an argument schema or custom
description. HITL requires a checkpointer because the run pauses at a graph
interrupt and resumes later.

```elixir
case MyApp.EngineeringAgent.invoke(input,
       checkpointer: checkpointer,
       config: %{"configurable" => %{"thread_id" => "review-1"}}
     ) do
  {:interrupted, interrupt} ->
    MyApp.EngineeringAgent.resume_review(
      %{decisions: [%{type: :approve}]},
      checkpointer: checkpointer,
      config: %{"configurable" => %{"thread_id" => "review-1"}}
    )
end
```

## Skills

Set `skills` to load `SKILL.md` metadata into the system prompt. Skills use
progressive disclosure: BeamWeaver reads frontmatter at startup, lists the
available skills, and instructs the model to read the full `SKILL.md` with
`read_file` only when relevant.

```elixir
skills ["/skills/base", {"/skills/project", "Project"}]
```

Configure a model-visible `filesystem` when the agent should read full skill
files or supporting assets during a run.

Each skill must have frontmatter with at least `name` and `description`:

```markdown
---
name: research
description: Find source-backed answers in project files.
allowed-tools: read_file grep
---

Use `grep` first, then read narrow file ranges.
```

Later skill sources override earlier ones by skill name. Metadata such as
`license`, `compatibility`, `metadata`, and `allowed-tools` is included in the
model-visible skill list.

For source precedence, store-backed skill libraries, subagent inheritance, and
unsupported interpreter-skill cases, see [Skills](skills.md).

## Memory Files

Set `memory true` to load `/AGENTS.md`, or pass one or more paths:

```elixir
memory ["/AGENTS.md", "/project/AGENTS.md"]
```

Memory files are always loaded into the system prompt through
`BeamWeaver.Agent.Middleware.Memory`. They are useful for durable preferences,
project conventions, and coding guidelines. They are different from
`BeamWeaver.Memory` stores, which are application-level long-term memory stores
used by tools and runtime code.

The memory middleware strips HTML comments before prompt injection and tells the
model to treat memory as reference material, not hidden higher-priority system
instructions. Agents can update memory by editing the configured files when the
user explicitly asks to remember reusable information.

For store-backed long-term memory files, including user-scoped, agent-scoped,
and organization-scoped namespaces, see [Memory](memory.md#filesystem-backed-agent-memory).

## Capability Profiles

`BeamWeaver.Agent.CapabilityProfile` is the native profile data structure for
provider or model-specific harness defaults:

```elixir
alias BeamWeaver.Agent.CapabilityProfile

:ok =
  CapabilityProfile.register_capability_profile(
    "anthropic:claude-sonnet-4-6",
    CapabilityProfile.new(
      system_prompt_suffix: "Use tools carefully and keep notes in files.",
      excluded_tools: ["execute"],
      tool_description_overrides: %{"grep" => "Search UTF-8 files for exact text."}
    )
  )

profile = CapabilityProfile.get_capability_profile("anthropic:claude-sonnet-4-6")
```

`CapabilityProfileConfig` is the serializable shape for storing or shipping
profile configuration. Profiles support base prompt text, prompt suffixes,
extra middleware, excluded middleware, excluded tools, tool-description
overrides, and general-purpose subagent metadata.

Normal BeamWeaver agent builds do not automatically apply capability profiles as
a harness overlay; direct agent options remain the runtime source of truth. See
[Profiles](profiles.md) for the full split between capability, provider, and
model profiles.

## Unsupported Or Different From Official Deep Agents Docs

BeamWeaver intentionally differs from the official Python Deep Agents harness
in these places:

- No separate `create_deep_agent`: use `BeamWeaver.Agent.build/1` or
  `use BeamWeaver.Agent`.
- No implicit default model: `BeamWeaver.Agent.build/1` requires `:model` so
  deployments do not silently select a provider or spend credentials.
- Planning is normal middleware. The top-level default tool name is `todo`, and
  TODO statuses are `open` and `complete`; configure `tool_name: "write_todos"`
  when you want the official tool name.
- No automatic `general-purpose` subagent is injected by normal agent build.
  Pass explicit `subagents` or `async_subagents`.
- `CapabilityProfile` exists as native profile data and registry, but normal
  agent options remain the runtime source of truth. Python entry-point plugin
  packaging for harness profiles is not a BeamWeaver API.
- QuickJS-style interpreter support and an `eval` tool are not implemented.
  Use executable filesystem backends or `ShellTool` for code execution.
- Multimodal `read_file` handling is narrower than the official extension
  table. BeamWeaver supports UTF-8 text, base64 binary file data, and raw
  byte downloads, but it does not yet classify every video, audio, PDF, and
  presentation extension into provider-specific content blocks.
- Filesystem permissions do not secure arbitrary shell execution. Treat
  `execute` and shell tools as separate sandbox or policy decisions.
- Managed Deep Agents, Harbor, LangSmith Agent Server, and hosted deployment
  workflows are outside BeamWeaver's built-in scope.
- Subagent work launched by the `task` tool is a tool invocation, not a
  statically declared graph subgraph node. Graph introspection can discover
  compiled graph nodes; it cannot infer arbitrary agent calls hidden inside
  tool handlers.

## Related

- [Agents](agents.md)
- [Profiles](profiles.md)
- [Filesystem](filesystem.md)
- [Filesystem Permissions](permissions.md)
- [Skills](skills.md)
- [Sandboxes](sandboxes.md)
- [Subagents](subagents.md)
- [Async Subagents](async_subagents.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Tools](tools.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Memory](memory.md)
- [Short-Term Memory](short_term_memory.md)
- [Long-Term Memory](long_term_memory.md)
- [Subgraphs](subgraphs.md)
