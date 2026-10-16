# Skills

A skill is a folder with a `SKILL.md` file: instructions for one kind of task,
plus any scripts, templates or reference files it needs. The agent sees a
short description of each skill and reads a skill in full only when a task
calls for it, so it can have many skills without a longer prompt on every
call.

```elixir
refund_policy = """
---
name: refund-policy
description: Decide whether an order qualifies for a refund and how much. Use for refund and return questions.
---

# Refund policy

1. Damaged or missing items: full refund, no return needed.
2. Unwanted items: refund within 30 days of delivery, minus shipping.
3. Refunds over $500 need a manager; say so instead of promising one.
"""

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("read_file", %{"file_path" => "/skills/refund-policy/SKILL.md"}),
      "Your mug arrived broken, so you get a full refund and don't need to send it back."
    ]

  system_prompt "You are Acme's support researcher."
  filesystem BeamWeaver.Filesystem.State.new()
  skills ["/skills"]
end

{:ok, result} =
  MyApp.SupportResearcher.invoke(%{
    messages: ["My mug arrived broken. Can I get my money back?"],
    files: %{"/skills/refund-policy/SKILL.md" => refund_policy}
  })

result.messages |> Enum.find(&(&1.role == :tool)) |> BeamWeaver.Core.Message.text()
#=> "---\nname: refund-policy\n" <> _
```

`skills ["/skills"]` lists the skills under `/skills` in the agent's system
prompt. The question matched the description of `refund-policy`, so the model
read the skill with `read_file` and answered from it. Here the skill is a file
in the thread's state, passed in with `files:`;
[Where skills live](#where-skills-live) keeps skills in a directory or a
memory store instead.

## Write a skill

Name the folder after the skill and put `SKILL.md` in it, next to any files
the skill refers to:

```text
skills/
├── refund-policy/
│   └── SKILL.md
└── order-export/
    ├── SKILL.md
    └── export.sh
```

`SKILL.md` starts with YAML frontmatter, followed by the instructions in
Markdown:

| Field | Meaning |
| --- | --- |
| `name` | Required. Lowercase letters, digits and hyphens, at most 64 characters, the same as the folder's name. |
| `description` | Required, at most 1,024 bytes. What the skill is for and when to use it: the model picks skills by this text, so make it specific. |
| `license`, `compatibility` | Optional. Shown to the model next to the description. |
| `allowed-tools` | Optional. Tool names, separated by spaces, shown to the model as advice. It doesn't limit which tools the agent may call. |
| `metadata` | Optional. A map of strings for your own use. |

`argument-hint`, `disable-model-invocation`, `user-invocable` and `context`
are accepted but don't change what the agent does, and any other field makes
the skill invalid. In the body, name the supporting files by path and say
when to use them, such as "run `/skills/order-export/export.sh` for more than
100 orders", so the agent opens them only when it needs them.

`BeamWeaver.Skill.parse/2` checks a `SKILL.md` the way the agent does and
returns `{:ok, %BeamWeaver.Skill{}}` or the reason it fails. Call it in a test
to catch a broken skill before an agent skips it:

```elixir
BeamWeaver.Skill.parse("---\nname: Refund Policy\ndescription: Refunds.\n---\n")
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_skill, message: "skill name is invalid"}}
```

## What the model sees

Before the first model call of every run, the agent reads the frontmatter of
each skill and adds a section like this to its system prompt:

```text
**Available Skills:**

- **refund-policy**: Decide whether an order qualifies for a refund and how much. Use for refund and return questions.
  -> Read `/skills/refund-policy/SKILL.md` for full instructions

**How to Use Skills (Progressive Disclosure):**

Check whether the user's task matches an available skill. When it does, read the listed `SKILL.md` path with `read_file` before using the skill.
```

The section also names the folders it searched and lists each skill it
couldn't load, with the reason. A skill costs a line or two of prompt until
the model reads it, and because the list is read on every run, a new or
changed skill shows up on the next run, even in the same thread.

## Skill sources

`skills` takes a list of sources:

| Source | Loads |
| --- | --- |
| `"/skills"` | every folder in `/skills` that has a `SKILL.md` |
| `"/skills/refund-policy"` | that one skill |
| `{"/skills/support_team", "Support team"}` | the folder's skills, with a label for the prompt |

When two sources hold a skill with the same name, the later source wins. List
general skills first and more specific ones after them, so a team can replace
a company-wide skill with its own version:

```elixir
model "fake:chat"
filesystem BeamWeaver.Filesystem.State.new()
skills [{"/skills/acme", "Acme"}, {"/skills/support_team", "Support team"}]
```

Declare a `filesystem` with `skills`. The agent reads the list of skills
through it, and its file tools let the model open them. Without a
`filesystem`, the skills come from the thread's state and the model has no
`read_file` to open one.

## Where skills live

Skills are files, so they live wherever the agent's filesystem keeps them
([Filesystem](filesystem.md)). Skills that ship with your application belong
in a directory, mounted read-only:

```elixir
defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Filesystem

  model "anthropic:claude-sonnet-4-6"

  filesystem Filesystem.Composite.new(
               routes: %{"/skills/" => Filesystem.Local.new(root: Application.app_dir(:my_app, "priv/skills"))}
             )

  filesystem_permissions [Filesystem.Permission.new(operations: [:write], paths: ["/skills/**"], mode: :deny)]
  skills ["/skills"]
end
```

The agent finds `priv/skills/refund-policy/SKILL.md` at
`/skills/refund-policy/SKILL.md`, and its other files stay in the thread's
state. Skills you edit while the application runs, or keep per customer, fit a
memory store. Upload them once, and every run reads the current version:

```elixir
store = BeamWeaver.Memory.ETS.new()
library = BeamWeaver.Filesystem.Store.new(store: store, namespace: ["acme", "skills"])
[%{error: nil}] = BeamWeaver.Filesystem.upload_files(library, [{"/refund-policy/SKILL.md", refund_policy}])

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("read_file", %{"file_path" => "/skills/refund-policy/SKILL.md"}),
      "Your mug arrived broken, so you get a full refund."
    ]

  filesystem Filesystem.Composite.new(routes: %{"/skills/" => Filesystem.Store.new(namespace: ["acme", "skills"])})
  filesystem_permissions [Filesystem.Permission.new(operations: [:write], paths: ["/skills/**"], mode: :deny)]
  skills ["/skills"]
end

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["My mug arrived broken."]}, store: store)
result.messages |> Enum.find(&(&1.role == :tool)) |> BeamWeaver.Core.Message.text()
#=> "---\nname: refund-policy\n" <> _
```

`upload_files/3` replaces a skill that already exists. A `namespace:` function
gives each customer or team their own library; see
[Memory Files](memory_files.md#one-set-of-files-per-customer). The store must
be a `Memory.ETS` for now (see [Filesystem](filesystem.md#a-memory-store)).

## Skills for subagents

The built-in `general-purpose` subagent gets the parent's skills and file
tools. A subagent module of your own loads the `skills` it declares through
its own `filesystem`, as it does when it runs on its own. To give it the
parent's skills and files instead, ask for them on its `subagent` line with
`base_middleware:`. It then loads its own `skills` declaration, or the
parent's if it has none, from the parent's filesystem:

```elixir
model "fake:chat"
filesystem BeamWeaver.Filesystem.State.new()
skills ["/skills"]

subagents do
  subagent MyApp.PolicyExpert,
    base_middleware: [BeamWeaver.Agent.Middleware.Skills, BeamWeaver.Agent.Middleware.Filesystem]
end
```

`skills: [...]` on the same line replaces both. A subagent started with
`async_subagents` runs on another server and loads its skills there. See
[Subagents](subagents.md).

## Skills that run scripts

Any filesystem lets the agent read a skill's scripts and templates. Running a
script needs the `execute` tool, from a filesystem that runs commands:
`BeamWeaver.Filesystem.LocalShell` for development, or
`BeamWeaver.Filesystem.Sandbox` to isolate the commands
([Sandboxes](sandboxes.md)). A command sees only the files of the backend
that runs it, not files mounted from other backends, so keep such skills in
that backend, or copy them in with `BeamWeaver.Filesystem.upload_files/3`
before the run. Logic your application can run itself, such as a database
query, is simpler and safer as a [tool](tools.md).

## Skills, memory files or tools?

| | Skills | Memory files | Tools |
| --- | --- | --- | --- |
| In every prompt | the name and description | the whole file | the name, description and arguments |
| Use for | procedures and reference that some tasks need | short rules and facts for every task | actions and data from your systems |
| Changed by | you, as files | you, and the agent with `edit_file` | your code |
| Enforced | no, the model follows them | no, the model follows them | yes, your code runs |

Most deep agents use all three: tools to act, a [memory file](memory_files.md)
for house rules, and skills for the procedures behind them. Move a long
section of a memory file into a skill when only some tasks need it.

## Reference

- [`BeamWeaver.Agent.Middleware.Skills`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Skills.html): loads skills and adds the list to the system prompt
- [`BeamWeaver.Skill`](https://hexdocs.pm/beam_weaver/BeamWeaver.Skill.html): parses and checks `SKILL.md` files
- [`BeamWeaver.Filesystem.Store`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.Store.html): skills kept in a memory store
- [`BeamWeaver.Filesystem.Composite`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.Composite.html): a skills folder mounted next to other files
- [`BeamWeaver.Agent.Subagent.Spec`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Subagent.Spec.html): subagent options such as `base_middleware` and `skills`
