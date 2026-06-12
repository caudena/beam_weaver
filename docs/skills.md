# Skills

Skills are reusable agent capabilities packaged as files. Use them for
specialized workflows, domain instructions, examples, reference docs, templates,
and helper scripts that would be too large or too task-specific to keep in the
base system prompt.

BeamWeaver follows the Agent Skills shape used by Deep Agents: each skill lives
in a directory with a `SKILL.md` file, YAML frontmatter, and optional supporting
files. BeamWeaver loads skill metadata up front and tells the model to read the
full `SKILL.md` only when the user's task matches the skill. This is progressive
disclosure.

## What A Skill Contains

A skill directory usually looks like this:

```text
skills/
|-- langgraph-docs/
|   `-- SKILL.md
`-- arxiv-search/
    |-- SKILL.md
    `-- search.exs
```

`SKILL.md` starts with frontmatter and then normal Markdown instructions:

````markdown
---
name: langgraph-docs
description: Use this skill for LangGraph documentation questions. Fetch the docs index, choose relevant pages, and answer with references.
license: MIT
compatibility: Requires network access through a fetch_url tool.
metadata:
  owner: docs
allowed-tools: fetch_url read_file
---

# langgraph-docs

## Overview

Use this skill when a user asks about LangGraph APIs or implementation details.

## Instructions

1. Fetch `https://docs.langchain.com/llms.txt`.
2. Select the most relevant pages.
3. Fetch those pages and answer from the docs.
4. Include reference links.
````

At minimum, frontmatter needs `name` and `description`. BeamWeaver also reads
`license`, `compatibility`, `metadata`, and `allowed-tools`.

Supporting files are not discovered semantically by the runtime. Reference them
from `SKILL.md` and explain when to read or execute them so the agent can decide
what to load.

{% hint style="info" %}
**Name Skills Like Agent Skills**

Use lowercase kebab-case names that match the containing directory, for example
`langgraph-docs/SKILL.md` with `name: langgraph-docs`. BeamWeaver records
whether the name matches the Agent Skills convention; it does not currently
reject mismatches.
{% endhint %}

## How Skills Work

When an agent starts a run, `BeamWeaver.Agent.Middleware.Skills` loads only
metadata from configured `SKILL.md` files. It stores the metadata in a private
state channel and appends a "Skills System" section to the model prompt.

The prompt tells the model to:

1. Check whether the current task matches a listed skill description.
2. Use `read_file` to read the full `SKILL.md` when a skill applies.
3. Follow the skill instructions and load any referenced files as needed.

Only configured skill sources are scanned. BeamWeaver does not automatically
scan CLI directories such as `~/.deepagents` or `~/.agents`.

## Basic Usage

Configure both `filesystem` and `skills` for the normal progressive-disclosure
flow. The skills middleware uses the filesystem to load metadata, and the
filesystem tools let the model read full `SKILL.md` files.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Core.Message
alias BeamWeaver.Filesystem

files = %{
  "/skills/langgraph-docs/SKILL.md" => %Filesystem.FileData{
    encoding: "utf-8",
    content: """
    ---
    name: langgraph-docs
    description: Use this skill for LangGraph documentation questions.
    allowed-tools: read_file fetch_url
    ---

    # langgraph-docs

    Read the docs index, select relevant pages, and answer with references.
    """
  }
}

{:ok, agent} =
  Agent.build(
    model: "openai:gpt-5.4",
    filesystem: Filesystem.State.new(),
    skills: ["/skills"]
  )

{:ok, _state} =
  Agent.invoke(agent, %{
    messages: [Message.user("What is LangGraph?")],
    files: files
  })
```

Module-defined agents use the same settings:

```elixir
defmodule MyApp.DocsAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4"
  filesystem BeamWeaver.Filesystem.State.new()
  skills ["/skills"]
end
```

`skills` entries can point at:

| Source | Behavior |
| --- | --- |
| `"/skills"` | Load immediate child directories such as `/skills/research/SKILL.md`. |
| `"/skills/research"` | Load `/skills/research/SKILL.md` as one skill. |
| `"/skills/research/SKILL.md"` | Load that exact file as one skill. |
| `{"/skills/project", "Project"}` | Load a source with a custom label in the prompt. |

## Store-Backed Skills

Use `BeamWeaver.Filesystem.Store` when skills should live in durable
`BeamWeaver.Memory` storage instead of thread state or local disk.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Filesystem
alias BeamWeaver.Memory

store = Memory.ETS.new()

filesystem =
  Filesystem.Composite.new(
    default: Filesystem.State.new(),
    routes: %{
      "/skills/" =>
        Filesystem.Store.new(
          store: store,
          namespace: ["skills", "builtin"]
        )
    }
  )

%Filesystem.WriteResult{error: nil} =
  Filesystem.write(
    filesystem,
    "/skills/langgraph-docs/SKILL.md",
    """
    ---
    name: langgraph-docs
    description: Use this skill for LangGraph documentation questions.
    ---

    # langgraph-docs

    Fetch the documentation index and selected source pages before answering.
    """,
    store: store
  )

{:ok, agent} =
  Agent.build(
    model: "openai:gpt-5.4",
    store: store,
    filesystem: filesystem,
    skills: ["/skills"]
  )
```

Namespace factories can read trusted runtime context, which is useful for
user-scoped or agent-scoped skill libraries:

```elixir
filesystem =
  Filesystem.Composite.new(
    default: Filesystem.State.new(),
    routes: %{
      "/skills/" =>
        Filesystem.Store.new(
          store: store,
          namespace: fn runtime ->
            ["users", runtime.context.user_id, "skills"]
          end
        )
    }
  )

{:ok, agent} =
  Agent.build(
    model: "openai:gpt-5.4",
    store: store,
    filesystem: filesystem,
    skills: ["/skills"],
    context_schema: %{user_id: %{type: :string, required: true}}
  )
```

Derive skill namespaces from trusted application context, not from
model-provided tool arguments.

## Source Precedence

When multiple sources contain a skill with the same `name`, the later source in
the `skills` list wins.

```elixir
skills [
  {"/skills/base", "Base"},
  {"/skills/project", "Project"}
]
```

If both sources contain `research/SKILL.md` with `name: research`, the project
version replaces the base version in the model-visible skills list. Use this for
layering built-in, user, organization, and project skills.

## What The Model Sees

The skills prompt includes:

- configured skill source locations,
- any load warnings, wrapped as untrusted diagnostics,
- each skill name and description,
- optional license and compatibility fields,
- optional `allowed-tools` text,
- the path to read for full instructions.

Example prompt entry:

```text
- **research**: Find source-backed answers in project files (License: MIT)
  -> Allowed tools: read_file, grep
  -> Read `/skills/project/research/SKILL.md` for full instructions
```

`allowed-tools` is advisory metadata for the model. It does not enforce tool
access. Use explicit tool lists, tool-selection middleware, filesystem
permissions, or custom middleware when access must be enforced.

## Skills For Subagents

Synchronous BeamWeaver subagents are agent modules. The child module owns its
skill sources, prompt, tools, middleware, and schema. The parent only decides
which subagent tools are available and whether outputs are captured.

```elixir
defmodule MyApp.SupervisorAgent do
  use BeamWeaver.Agent

  subagents do
    subagent MyApp.Agents.Researcher
    subagent MyApp.Agents.MinimalWorker
  end
end

defmodule MyApp.Agents.Researcher do
  use BeamWeaver.Agent

  name "researcher"
  description "Researches source-backed questions."
  system_prompt "Use research skills when they match the task."
  skills ["/skills/research"]
end

defmodule MyApp.Agents.MinimalWorker do
  use BeamWeaver.Agent

  name "minimal_worker"
  description "Runs without skill context."
  system_prompt "Answer only from the prompt."
  skills []
end
```

Async subagents run as separate agents or protocol servers. Configure their
skills in the target agent definition; the supervisor's skill state is not
transferred automatically to a remote async agent.

## Code And Script Skills

Skills can include helper scripts, templates, or reference files. BeamWeaver can
read those files through the configured filesystem. Running them depends on the
filesystem:

| Need | BeamWeaver approach |
| --- | --- |
| Deterministic helper logic | Prefer normal Elixir tools, toolkits, or middleware. |
| Read scripts as reference | Put scripts under the skill directory and reference them in `SKILL.md`. |
| Execute scripts | Use a filesystem that implements `BeamWeaver.Filesystem.Executable`, such as `LocalShell` for trusted development or a sandbox filesystem for isolation. |
| Store-backed skills plus sandbox execution | Copy needed skill files into the executable filesystem with application code or custom middleware before execution. |

BeamWeaver does not currently implement Deep Agents interpreter skills,
QuickJS, `CodeInterpreterMiddleware`, or the `@/skills/<name>` JavaScript
import alias. A `module:` frontmatter field may be present for portability, but
the built-in BeamWeaver skills middleware does not execute it.

## Skills Vs Memory

| | Skills | Memory |
| --- | --- | --- |
| Purpose | Task-specific workflows and domain packages. | Always-relevant preferences, project rules, and durable facts. |
| Loading | Metadata first; full content read on demand. | Configured files are always injected into the system prompt. |
| Format | `SKILL.md` in named directories. | `AGENTS.md` or other memory file paths. |
| Good for | Large procedural instructions, templates, optional docs, scripts. | Short conventions, user preferences, organization policies. |
| Risk | Overlapping descriptions make selection harder. | Large memory files bloat every model call. |

Put always-relevant conventions in [Memory](memory.md). Put large or optional
workflows in skills.

## When To Use Skills Or Tools

Use skills when:

- the capability needs substantial instructions or examples,
- the workflow is optional and task-specific,
- supporting files are useful but should not always enter context,
- you want to layer user, organization, or project guidance.

Use tools when:

- the agent needs to perform an action or fetch data,
- the capability must be enforced by code,
- the agent does not have model-visible filesystem access,
- the logic should be deterministic and compact.

Most production agents use both: tools perform actions, while skills teach the
agent when and how to combine them.

## Related

- [Composed Agent Capabilities](agent_harness.md)
- [Filesystem](filesystem.md)
- [Filesystem Permissions](permissions.md)
- [Sandboxes](sandboxes.md)
- [Memory](memory.md)
- [Subagents](subagents.md)
- [Context Engineering](context_engineering.md)
- [Tools](tools.md)
