# Capability Profiles

Capability profiles tune agent behavior for a model: prompt additions, tool
visibility, descriptions and middleware. They are separate from **model
profiles**, which describe provider capabilities and context limits.
Use [Models](models.md#model-profiles) for compatibility metadata.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Apply a profile

After [Installation](installation.md), this real OpenAI agent uses a local
profile to add a response convention:

```elixir
defmodule MyApp.ProfiledAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
  system_prompt "Follow the response convention supplied below."

  capability_profile BeamWeaver.Agent.CapabilityProfile.new(
                       prompt_suffix: "When asked for the readiness marker, reply exactly PROFILE_READY."
                     )
end

{:ok, result} = MyApp.ProfiledAgent.invoke(%{messages: ["Return the readiness marker."]})
"PROFILE_READY" = result.messages |> List.last() |> BeamWeaver.Core.Message.text() |> String.trim()
```

`capability_profile :auto` selects a registered profile using the model
identifier. Without a declaration, a profile is data and does not change an
agent. Declarations are re-evaluated on each invocation.

## What a profile holds

| Field | Applied behavior |
| --- | --- |
| `base_system_prompt` | Used when the agent has no explicit system prompt |
| `prompt_suffix` | Added to the agent's prompt |
| `excluded_tools` | Merged into hidden tools |
| `tool_descriptions` | Model-visible description overrides; agent-specific values win |
| `middleware` | Additional middleware; explicit agent entries of the same module win |
| `excluded_middleware` | Data for application policy; not automatically enforced |
| `general_purpose_subagent` | Configuration to explicitly include in subagent declarations |

A prompt suffix guides behavior but cannot grant capabilities an API lacks.
Tool-side authorization still applies independently of profile selection.

## Built-in profiles

Inspect the registry instead of copying a list that can drift:

```elixir
alias BeamWeaver.Agent.CapabilityProfile
profile = CapabilityProfile.get_capability_profile("anthropic:claude-sonnet-4-6")
true = byte_size(profile.prompt_suffix) > 0
```

```elixir
keys = CapabilityProfile.builtin_keys()
true = "openai:gpt-5.4-mini" in keys
```

Lookup first considers provider/model data and falls back to provider tuning.
Unsupported providers can have no registered entry; `for_model/2` returns an
empty profile in that case. Keys are split at the first colon, preserving
model IDs that contain additional colons.

## Define your own

Construct a profile locally, as above, when one agent needs it. Register a
shared profile once during application startup with
`register_capability_profile/2`; the registry is node-wide, so registration
inside a request affects other callers.

A newer/more specific profile overrides prompt text, merges descriptions by
tool name and middleware by module, and combines excluded entries.
`merge/2` exposes that composition explicitly.

For database or file configuration, use `CapabilityProfileConfig`:

```elixir
alias BeamWeaver.Agent.CapabilityProfileConfig
config = CapabilityProfileConfig.from_map(%{"system_prompt_suffix" => "Be brief.", "excluded_tools" => ["execute"]})
["execute"] = CapabilityProfileConfig.to_capability_profile(config).excluded_tools
```

The serializable config omits executable middleware. Validate persisted
configuration before applying it to a running agent.

## The general-purpose subagent

A parent with subagents can offer a built-in `general-purpose` worker. A
`GeneralPurposeSubagentProfile` controls its enabled state, description and
prompt when included in the subagent declaration list. Merely storing that
field in a capability profile does not install it.

A custom subagent named `"general-purpose"` replaces the built-in worker.
Its spec controls model/tools and inherited base middleware. Explicit
subagents do not automatically receive every parent policy; declare the
capabilities they require. See [Subagents](subagents.md).

Customize the worker’s instructions and actually delegate to it:

```elixir
defmodule MyApp.ProfiledSupervisor do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Delegate the supplied calculation to general-purpose exactly once."

  subagents [
    BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(
      system_prompt: "Solve the supplied task briefly. Include the numeric result."
    )
  ]
end

{:ok, result} = MyApp.ProfiledSupervisor.invoke(%{messages: ["Ask general-purpose to calculate 19 + 23."]})
reply = Enum.find(result.messages, &(&1.role == :tool and &1.name == "task"))
true = BeamWeaver.Core.Message.text(reply) =~ "42"
```
