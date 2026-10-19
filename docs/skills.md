# Skills

A skill packages task instructions and supporting files in a folder with
`SKILL.md`. The agent sees a short description first and reads the full
procedure when needed. Use skills for repeatable procedures; use tools for
application-enforced actions and memory files for short always-loaded notes.

Complete [Installation](installation.md). This example uses a real OpenAI
model and a skill stored in the thread's filesystem.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Give an agent a procedure

```elixir
skill_text = """
---
name: refund-policy
description: Explain the sample damaged-goods refund policy. Use for damaged delivery questions.
---
# Damaged goods

Read the customer report. A damaged item is eligible for a full refund after
staff approval. Explain eligibility; do not claim a payment has been made.
"""

defmodule MyApp.SkilledAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Read the relevant SKILL.md before answering a policy question."
  filesystem BeamWeaver.Filesystem.State.new()
  skills ["/skills"]
end

{:ok, result} =
  MyApp.SkilledAgent.invoke(%{
    messages: ["My mug arrived broken. Read the refund-policy skill and explain what I am eligible for."],
    files: %{"/skills/refund-policy/SKILL.md" => skill_text}
  })

read = Enum.find(result.messages, &(&1.role == :tool and &1.name == "read_file"))
true = read != nil
true = BeamWeaver.Core.Message.text(read) =~ "staff approval"
answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = String.downcase(answer) =~ "refund"
```

The tool result establishes that the procedure was actually read. The sample
policy is teaching data. A skill's text guides the model; it does not itself
enforce approval or authorize a real refund.

## Write a skill

Use a folder whose name matches the skill, with `SKILL.md` and any supporting
scripts, templates or references beside it. Frontmatter precedes Markdown.

| Field | Contract |
| --- | --- |
| `name` | Required; lowercase letters/digits/hyphens, at most 64 characters, matching folder name |
| `description` | Required; explain when to use it; overlong descriptions are truncated with a warning |
| `license`, `compatibility` | Optional discovery metadata |
| `allowed-tools` | Advisory tool names, not an enforced permission policy |
| `metadata` | Optional string-keyed metadata |

Write steps with inputs, expected outputs and completion criteria. Identify
supporting files explicitly and tell the agent when to read or run them.
Do not bury authorization in prose when it belongs in a tool or review rule.

```elixir
{:ok, skill} = BeamWeaver.Skill.parse(skill_text)
"refund-policy" = skill.name
```

The parser also supports literal `$ARGUMENTS` substitution through `render/2`.
It does not execute shell substitutions or treat arbitrary template syntax as
code. Pass a binary argument string; the renderer substitutes it literally.

Render literal invocation arguments without interpreting them as shell code:

```elixir
{:ok, template} =
  BeamWeaver.Skill.parse(
    "---\nname: order-note\ndescription: Write an order note.\n---\nWrite a note about $ARGUMENTS."
  )

{:ok, rendered} = BeamWeaver.Skill.render(template, "A-1001")
true = rendered =~ "Write a note about A-1001."
```

## What the model sees

At the start of a run, discovery adds skill names, descriptions and paths to
the prompt. Full instructions remain in files until read. Invalid/unloadable
skills are reported in discovery information rather than silently becoming
working procedures. Changed files are discovered on subsequent runs.

Keep descriptions specific so the model can choose among similar skills.
A huge skill catalog still costs prompt space even with progressive loading.

## Skill sources

`skills` accepts a directory of skills, a single skill folder or a
`{path, label}` source. When names collide, later sources override earlier
ones. Put general procedures first and tenant/team overrides later.

Declare a filesystem so the model has `read_file`. Without it, discovery can
read state-backed skill metadata while the model lacks the tool to open the
procedure.

Put general procedures first and a team override later. This example reads the actual overridden procedure:

```elixir
defmodule MyApp.TeamSkillsAgent do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Read the refund-policy skill before answering."
  filesystem BeamWeaver.Filesystem.State.new()
  skills [{"/skills/shared", "Shared"}, {"/skills/team", "Team"}]
end

team_policy = String.replace(skill_text, "full refund after", "replacement after")

{:ok, result} =
  MyApp.TeamSkillsAgent.invoke(%{
    messages: ["Read refund-policy and explain the policy for damaged deliveries."],
    files: %{
      "/skills/shared/refund-policy/SKILL.md" => skill_text,
      "/skills/team/refund-policy/SKILL.md" => team_policy
    }
  })

read = Enum.find(result.messages, &(&1.role == :tool and &1.name == "read_file"))
true = BeamWeaver.Core.Message.text(read) =~ "replacement after"
```

## Where skills live

Bundled skills can live under `priv/skills` in your application and be mounted
read-only through a Local/Composite backend. Editable team/tenant skills can
live in `Filesystem.Store`, backed by ETS or persistent memory storage.
A store namespace function selects the authenticated tenant.

Uploads replace existing files. Validate new skill text and supporting paths
before exposing it. Keep shared procedures read-only to ordinary agent tasks
when modification is not part of their authority.

Load a procedure into an application-owned store and use it through a mounted route:

```elixir
store = BeamWeaver.Memory.ETS.new()
library = BeamWeaver.Filesystem.Store.new(store: store, namespace: ["acme", "skills"])
[%{error: nil}] = BeamWeaver.Filesystem.upload_files(library, [{"/refund-policy/SKILL.md", skill_text}])

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 512, timeout: 60_000],
    system_prompt: "Read the refund-policy SKILL.md before answering.",
    filesystem: BeamWeaver.Filesystem.Composite.new(routes: %{"/skills/" => library}),
    skills: ["/skills"]
  )

{:ok, result} =
  BeamWeaver.Agent.invoke(agent, %{messages: ["Read refund-policy. What happens after a damaged delivery?"]})

true =
  Enum.any?(
    result.messages,
    &(&1.role == :tool and &1.name == "read_file" and BeamWeaver.Core.Message.text(&1) =~ "staff approval")
  )
```

## Skills for subagents

The general-purpose worker inherits parent skills and file tools. An explicit
child normally uses its own declarations. Request parent filesystem/skills
middleware through `base_middleware:` when inheritance is intended; a spec's
`skills:` can override the source list. Remote async agents load their skills
in their own service environment.

An explicit specialist requests the parent’s file and skill capabilities. The captured answer comes from a real delegated run:

```elixir
defmodule MyApp.SkilledPolicyChild do
  use BeamWeaver.Agent
  name "policy_reader"
  description "Reads the refund-policy skill and explains its procedure."
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Read the refund-policy SKILL.md before answering."
end

defmodule MyApp.SkillSupervisor do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Delegate policy questions to policy_reader exactly once."

  middleware [
    {BeamWeaver.Agent.Middleware.ToolChoice,
     choice: fn request ->
       if Enum.any?(request.messages, &(&1.role == :tool)),
         do: :none,
         else: %{type: "function", function: %{name: "task"}}
     end}
  ]

  filesystem BeamWeaver.Filesystem.State.new()
  skills ["/skills"]

  subagents do
    subagent MyApp.SkilledPolicyChild,
      capture_output: :policy,
      base_middleware: [BeamWeaver.Agent.Middleware.Skills, BeamWeaver.Agent.Middleware.Filesystem]

    include [BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)]
  end
end

{:ok, result} =
  MyApp.SkillSupervisor.invoke(%{
    messages: ["Read the skill and explain the damaged-delivery refund procedure."],
    files: %{"/skills/refund-policy/SKILL.md" => skill_text}
  })

true = is_binary(result.subagent_outputs["policy"])
true = String.downcase(result.subagent_outputs["policy"]) =~ "approval"
```

## Skills that run scripts

Reading a script requires file tools; executing it requires an executable
backend. A command sees that backend's actual files, not every virtual mount
in a composite filesystem. Copy required scripts into the execution backend
or keep them there. [Sandboxes](sandboxes.md) explains execution policies and
resource ownership.

## Skills, memory files or tools?

| Mechanism | Best for | Enforcement |
| --- | --- | --- |
| Skill | Procedure loaded for relevant tasks | Model follows instructions |
| Memory file | Short notes/instructions needed each run | Model follows reference text |
| Tool | Data access or a concrete action | Your application executes and validates it |
