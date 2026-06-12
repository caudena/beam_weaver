# Profiles

BeamWeaver has profiles, but the names and integration points are not a
one-for-one copy of the Python Deep Agents page. There are three distinct
profile concepts:

| Profile kind | BeamWeaver API | Controls | Automatic? |
| --- | --- | --- | --- |
| Capability profile | `BeamWeaver.Agent.CapabilityProfile` and `BeamWeaver.Agent.CapabilityProfileConfig` | Compatibility/profile data such as prompt suffixes, model-visible tool descriptions, excluded tools, excluded middleware, extra middleware, and general-purpose subagent metadata. | Registry and merge logic exist; normal `BeamWeaver.Agent.build(...)` and `use BeamWeaver.Agent` builds do not automatically overlay these profiles. |
| Provider profile | `BeamWeaver.Agent.ProviderProfile` | Model-construction defaults for provider/model strings. | Yes, for binary or atom model identifiers passed to agents. |
| Model profile | `BeamWeaver.Models.Profile` and `BeamWeaver.Models.ProfileRegistry` | Provider/model capabilities such as context window, tool calling, structured output, streaming, modalities, tokenizer, and supported params. | Yes, through `BeamWeaver.Models.init_chat_model/2` and provider structs. |

Use provider profiles when you want model initialization defaults. Use model
profiles when you need capability metadata. Use capability profiles when you are
building your own compatibility layer and want serializable profile data that
mirrors Python Deep Agents profile shapes.

{% hint style="info" %}
**Short Answer**

Yes: provider profiles and model profiles are fully active in the normal agent
path. Capability profiles also exist with built-ins, registry lookup, merging,
and config serialization, but they are not currently an implicit agent-build
overlay. Direct agent options remain the runtime source of truth for composed
agent behavior.
{% endhint %}

## Capability Profiles

`BeamWeaver.Agent.CapabilityProfile` stores provider/model-specific
compatibility preferences inspired by Python Deep Agents profile data:

```elixir
alias BeamWeaver.Agent.CapabilityProfile

:ok =
  CapabilityProfile.register_capability_profile(
    "anthropic:claude-sonnet-4-6",
    CapabilityProfile.new(
      system_prompt_suffix: "Use tools carefully and keep notes in files.",
      excluded_tools: ["execute"],
      tool_description_overrides: %{
        "grep" => "Search UTF-8 files for exact text."
      },
      general_purpose_subagent: %{
        enabled: false
      }
    )
  )

profile = CapabilityProfile.get_capability_profile("anthropic:claude-sonnet-4-6")
```

Profile keys use the same provider or provider/model shape as the official
docs:

- Provider-level keys such as `"anthropic"` apply to every model for that
  provider.
- Model-level keys such as `"anthropic:claude-sonnet-4-6"` merge on top of the
  provider profile.
- There is no wildcard key for every provider.

BeamWeaver ships built-in capability profiles for Anthropic Claude 4.5/4.6/4.7
families and OpenAI Codex model names. Inspect the known keys at runtime:

```elixir
BeamWeaver.Agent.CapabilityProfile.builtin_keys()
```

### Fields

`CapabilityProfile.new/1` accepts these Deep Agents-compatible names:

| Field | Meaning |
| --- | --- |
| `:base_system_prompt` | Replacement base prompt text for custom composed-agent assembly. |
| `:system_prompt_suffix` or `:prompt_suffix` | Text to append to a custom assembled prompt. |
| `:tool_description_overrides` or `:tool_descriptions` | Map of tool name to model-visible description. |
| `:excluded_tools` | Tool names a custom harness should hide from the model. |
| `:excluded_middleware` | Middleware modules or public names a custom harness should drop. |
| `:extra_middleware` or `:middleware` | Extra middleware instances, modules, or a zero-arity factory. |
| `:general_purpose_subagent` | `%GeneralPurposeSubagentProfile{}` data or a map with `:enabled`, `:description`, and `:system_prompt`. |

The struct also has `:default_subagent?` for compatibility with the
general-purpose subagent profile. Normal BeamWeaver agent builds do not inject a
default `general-purpose` subagent; pass explicit `subagents` when you want a
`task` tool.

### Merge Semantics

Provider and exact-model capability profiles merge with additive semantics:

| Field | Merge behavior |
| --- | --- |
| `base_system_prompt`, `prompt_suffix` | Override wins when set. |
| `tool_descriptions` | Maps merge by tool name; override wins on conflicts. |
| `excluded_tools`, `excluded_middleware` | Lists are unioned. |
| `middleware` | Merged by concrete middleware key; override replaces matching base middleware and appends new entries. |
| `general_purpose_subagent` | Merged field by field. |

Re-registering a key merges the new profile over the existing one rather than
replacing it.

### Config Files

Use `BeamWeaver.Agent.CapabilityProfileConfig` for the serializable subset. It
round-trips maps that can be stored as JSON, YAML, or application config:

```elixir
alias BeamWeaver.Agent.{CapabilityProfile, CapabilityProfileConfig}

config =
  CapabilityProfileConfig.from_map(%{
    "system_prompt_suffix" => "Respond briefly.",
    "excluded_tools" => ["execute", "grep"],
    "tool_description_overrides" => %{
      "ls" => "List virtual files."
    },
    "general_purpose_subagent" => %{
      "enabled" => false
    }
  })

profile = CapabilityProfileConfig.to_capability_profile(config)
:ok = CapabilityProfile.register_capability_profile("openai:gpt-5.4", profile)
```

`CapabilityProfileConfig` intentionally excludes runtime-only fields such as
middleware instances and factories.

### Applying Harness Behavior

The profile registry is available for custom harness code:

```elixir
profile = CapabilityProfile.for_model(model, "anthropic:claude-sonnet-4-6")

middleware =
  profile
  |> CapabilityProfile.materialize_extra_middleware()
  |> Kernel.++(app_middleware)
```

For normal BeamWeaver agents, configure composed capability behavior directly on the agent:

```elixir
BeamWeaver.Agent.build(
  model: "anthropic:claude-sonnet-4-6",
  filesystem: BeamWeaver.Filesystem.State.new(),
  exclude_tools: ["execute"],
  tool_descriptions: %{"grep" => "Search project files."},
  subagents: [
    BeamWeaver.Agent.Subagent.Spec.new(
      name: "researcher",
      description: "Collect source-backed findings.",
      system_prompt: "Return concise findings with file paths."
    )
  ]
)
```

This explicit configuration is the supported path until capability profiles are
wired as a first-class automatic overlay.

## Provider Profiles

`BeamWeaver.Agent.ProviderProfile` is the active companion API for
model-construction defaults. It applies when an agent is built from a binary or
atom model identifier:

```elixir
alias BeamWeaver.Agent.ProviderProfile

:ok =
  ProviderProfile.register_provider_profile(
    "openai",
    ProviderProfile.new(init_kwargs: [temperature: 0])
  )

:ok =
  ProviderProfile.register_provider_profile(
    "openai:gpt-5.4",
    ProviderProfile.new(init_kwargs: [reasoning_effort: :medium])
  )

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4",
    tools: []
  )
```

Provider-level and exact-model profiles merge at resolution time. Caller-supplied
model options still win:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4",
    model_opts: [temperature: 0.2]
  )
```

Provider profiles support:

| Field | Meaning |
| --- | --- |
| `:init_kwargs` | Static options forwarded to model initialization. |
| `:model_opts` | Compatibility alias for model-construction options. |
| `:init_kwargs_factory` | Zero-arity function that returns runtime-derived options. |
| `:pre_init` | One-arity function called with the model spec before construction. |

Factories merge by running both and merging their results; `pre_init` callbacks
chain in registration order. BeamWeaver includes a built-in `"openai"` provider
profile that sets `use_responses_api: true` for agent model strings.

Passing a preconfigured model struct bypasses provider profiles because the
model has already been initialized:

```elixir
model =
  BeamWeaver.Models.init_chat_model!("openai:gpt-5.4",
    temperature: 0.2
  )

{:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [])
```

## Model Profiles

Model profiles are not Deep Agents capability profiles. They are BeamWeaver's
provider capability records:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4")

model.profile.max_input_tokens
BeamWeaver.Models.Profile.supports?(model.profile, :tool_calling)
BeamWeaver.Models.Profile.supports?(model.profile, :structured_output)
```

The agent and provider layers use model profiles to make capability decisions:
structured output strategy selection, context-window checks, summarization
thresholds, supported parameter validation, modality support, and tokenizer
selection.

Inspect checked-in model profiles:

```bash
mix beam_weaver.models.profiles
mix beam_weaver.models.profiles --provider openai --json
mix beam_weaver.models.profiles --provider anthropic --json
```

Override missing or stale model capability data explicitly:

```elixir
{:ok, model} =
  BeamWeaver.Models.init_chat_model("openai:future-model",
    profile: %{
      max_input_tokens: 200_000,
      tool_calling: true,
      structured_output: true,
      streaming: true
    }
  )
```

## Official Docs Differences

When porting from the Python Deep Agents profile page:

| Official Deep Agents term | BeamWeaver term |
| --- | --- |
| `HarnessProfile` | `BeamWeaver.Agent.CapabilityProfile` |
| `HarnessProfileConfig` | `BeamWeaver.Agent.CapabilityProfileConfig` |
| `ProviderProfile` | `BeamWeaver.Agent.ProviderProfile` |
| `GeneralPurposeSubagentProfile` | `BeamWeaver.Agent.GeneralPurposeSubagentProfile` |

Important differences:

- Capability profiles are not automatically applied by `BeamWeaver.Agent.build(...)`
  or `use BeamWeaver.Agent`; use direct agent options for runtime behavior.
- Python `importlib.metadata` entry points for profile plugins are not a
  BeamWeaver API. Register profiles from normal application startup code.
- Python `module:Class` string imports for excluded middleware are not
  supported. Use middleware modules or public middleware names in trusted Elixir
  config.
- There is no automatic default `general-purpose` subagent in normal agent
  builds. Configure explicit subagents instead.
- There is no wildcard profile key for all providers.
- Model profiles are a separate capability-metadata layer and should not be
  confused with provider profiles or capability profiles.

## Related

- [Composed Agent Capabilities](agent_harness.md)
- [Models](models.md)
- [Middleware](middleware.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Subagents](subagents.md)
- [Tools](tools.md)
