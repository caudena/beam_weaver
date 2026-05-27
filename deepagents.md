# DeepAgents Native Capability Refactor

## Summary

DeepAgents is now a BeamWeaver capability set, not a separate runtime API.
There is no `deep: true`, no profile flag, and no `BeamWeaver.DeepAgents`
constructor. A deep agent is a normal `BeamWeaver.Agent` that opts into native
features such as filesystem access, skills, memory, subagents, compaction,
overflow recovery, prompt caching, HITL, and sandbox execution.

Runtime construction uses the same API as every other BeamWeaver agent:

```elixir
BeamWeaver.Agent.build(
  model: model,
  filesystem: BeamWeaver.Filesystem.State.new(),
  skills: ["/skills"],
  memory: ["/AGENTS.md"],
  subagents: [...]
)
```

The DSL exposes the same capabilities:

```elixir
defmodule WorkspaceAgent do
  use BeamWeaver.Agent

  model "openai:gpt-4o-mini"
  filesystem BeamWeaver.Filesystem.State.new()
  skills ["/skills"]
  memory ["/AGENTS.md"]
  subagents [...]
end
```

## Native Runtime Surface

`BeamWeaver.Agent.build/1` and `use BeamWeaver.Agent` now accept these capability
fields:

- `filesystem`
- `filesystem_permissions`
- `skills`
- `memory`
- `subagents`
- `async_subagents`
- `compact_conversation`
- `overflow_recovery`
- `prompt_caching`
- `exclude_tools`
- `tool_descriptions`
- `interrupt_on`

Plain agents remain plain. No capability middleware, tools, state channels, or
recursion defaults are added unless a capability option or DSL macro is present.

## Promoted Modules

DeepAgents runtime modules were moved into native BeamWeaver namespaces:

- `BeamWeaver.Filesystem`
- `BeamWeaver.Filesystem.{State, Local, Store, Composite, Sandbox, LocalShell, Permission}`
- `BeamWeaver.Filesystem.Executable`
- `BeamWeaver.Tools.Filesystem`
- `BeamWeaver.Agent.Middleware.{Filesystem, Skills, Memory, CompactConversation, OverflowRecovery}`
- `BeamWeaver.Agent.Middleware.{PromptCaching, ToolCallNormalization, ToolFilter}`
- `BeamWeaver.Agent.Subagent.{Spec, Compiled, AsyncSpec, RunStream, AsyncRunStream, StreamTransformer}`
- `BeamWeaver.Agent.Protocol.{Client, ReqClient}`
- `BeamWeaver.Agent.{CapabilityProfile, CapabilityProfileConfig, ProviderProfile}`

`BeamWeaver.DeepAgents.*` runtime wrappers were removed. DeepAgents remains only
as a docs/examples/test label.

## Capability Expansion Rules

- `filesystem` adds filesystem tools and state support.
- Executable filesystems add `execute`.
- `skills` and `memory` use the configured filesystem, or state filesystem when
  none is supplied.
- `subagents` adds the supervised `task` tool.
- `async_subagents` adds async task tools. Async specs in `subagents` are routed
  to the async tool set used by the transferred examples.
- `compact_conversation` adds summarization and compact-conversation tooling.
- `overflow_recovery` adds overflow clipping and large tail offload.
- `prompt_caching` adds provider-specific prompt caching.
- `exclude_tools` and `tool_descriptions` use native tool selection and
  description override support.
- `interrupt_on` maps to BeamWeaver HITL middleware.
- Provider profiles hook into native model initialization for string model specs.

## Filesystem And Sandbox

Filesystem behavior is native under `BeamWeaver.Filesystem`:

- POSIX virtual paths
- file data v2 fields: `content`, `encoding`, `created_at`, `modified_at`
- `ls`, `read_file`, `write_file`, `edit_file`, `glob`, `grep`
- optional `execute` for executable filesystems
- state, local, store, composite, sandbox, and local-shell adapters
- path validation, symlink escape rejection, permissions, binary previews,
  read pagination, literal grep, glob timeouts, large result offload, and
  execute timeout validation

Real isolation comes from `BeamWeaver.Sandbox` adapters such as Docker with
Docker/gVisor/Kata runtime selection. `BeamWeaver.Sandbox.Local` and
`BeamWeaver.Filesystem.LocalShell` are trusted-development surfaces only.

## Subagents

Synchronous subagents use `BeamWeaver.Agent.Subagent.Spec` or `Compiled` and run
through BeamWeaver supervised child agent execution. Parent state filtering,
allowed child-state merge, structured JSON response return, `subagent_name` and
`subagent_type`, and typed stream summaries are preserved.

Async subagents use `BeamWeaver.Agent.Subagent.AsyncSpec` plus the minimal Agent
Protocol client surface needed by the transferred DeepAgents behavior.

## Evals

DeepAgents eval coverage is test-only. The harness lives under
`support/deep_agents/`, and focused tests live under
`test/beam_weaver/deep_agents/evals/`.

Run the eval coverage with:

- `mix test test/beam_weaver/deep_agents/evals`

Live provider and external sandbox eval paths remain config-gated inside those
tests.

## Verification

Current local checks:

- `mix test`

Final release checks should include:

- `mix format`
- `mix test`
- `rg "BeamWeaver\\.DeepAgents" lib test examples`
