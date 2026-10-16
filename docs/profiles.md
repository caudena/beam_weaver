# Capability Profiles

A capability profile holds per-model tuning for a deep agent: text to add to
the system prompt, tools to hide, new tool descriptions, extra middleware, and
settings for the general-purpose subagent. Use profiles when an agent runs on
several models and each model works best with its own adjustments.

<!-- snippet: run -->
```elixir
alias BeamWeaver.Agent.CapabilityProfile

profile = CapabilityProfile.get_capability_profile("anthropic:claude-sonnet-4-6")
profile.prompt_suffix
#=> "<use_parallel_tool_calls>\nWhen tool calls are independent, make them in parallel.\n" <> _
```

An agent applies a profile with the `capability_profile` declaration, as in
[Apply a profile](#apply-a-profile); without it, profiles are only data.

## What a profile holds

| Field | Holds | What `capability_profile` does with it |
| --- | --- | --- |
| `prompt_suffix` | text for the system prompt | adds it after your `system_prompt`, or after the prompt a `DynamicPrompt` middleware builds |
| `base_system_prompt` | a system prompt | uses it when the agent declares no `system_prompt` |
| `excluded_tools` | tool names to hide from the model | adds them to `exclude_tools` |
| `tool_descriptions` | new tool descriptions, by tool name | adds them to `tool_descriptions`; the agent's own win |
| `middleware` | extra middleware, or a function that returns it | runs it after the agent's `middleware`; an entry of the same module in the agent's list wins |
| `excluded_middleware` | middleware to leave out | nothing; read it in your own code |
| `general_purpose_subagent` | a description and prompt for the general-purpose subagent | nothing; see [a subagent of your own](#the-general-purpose-subagent) |

## Built-in profiles

BeamWeaver ships profiles for Anthropic and OpenAI models. The Anthropic ones
ask for parallel tool calls, reading before making claims, and a check of each
tool result; the OpenAI ones ask GPT-5 models to work like an autonomous
engineer. `CapabilityProfile.builtin_keys/0` lists them:

<!-- snippet: run -->
```elixir
CapabilityProfile.builtin_keys() |> Enum.filter(&String.starts_with?(&1, "openai"))
#=> ["openai:gpt-5.4", "openai:gpt-5.4-mini", "openai:gpt-5.5"]
```

A key is a provider, such as `"anthropic"`, or a provider and a model; a model
without its own profile gets its provider's. For other providers
`get_capability_profile/1` returns `nil`, and `CapabilityProfile.for_model/2`
an empty profile, so an agent that applies its model's profile works with any
model.

## Apply a profile

`capability_profile :auto` applies the profile of the agent's model: with
`model "anthropic:claude-sonnet-4-6"`, the built-in Anthropic text goes after
the system prompt. `capability_profile` also takes a profile you build, such
as one tuned for your own tools:

```elixir
defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.CapabilityProfile
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("glob", %{"pattern" => "*.md", "path" => "/policies"}),
      "Damaged items get a full refund."
    ]

  system_prompt "You are Acme's support researcher."
  filesystem BeamWeaver.Filesystem.State.new()
  capability_profile profile()

  def profile do
    CapabilityProfile.new(
      prompt_suffix: "Search with grep before you read whole files.",
      excluded_tools: ["glob"],
      tool_descriptions: %{"grep" => "Search Acme's policy files for exact text."}
    )
  end
end

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["Do I get a refund for a broken mug?"]})
result.messages |> Enum.find(&(&1.role == :tool)) |> BeamWeaver.Core.Message.text()
#=> "Tool error: tool is not registered" <> _
```

The profile hid `glob`, so the model's call was refused; it also added its
text after the system prompt and gave `grep` a new description. A
`BeamWeaver.Agent.CapabilityProfileConfig` works too. Like every declaration,
`capability_profile` is evaluated each time the agent runs, so a profile you
register later applies from the next call.

## Define your own

Register profiles once, when your application starts. Registering a key that
already has a profile, built-in or yours, merges the new one into it:

```elixir
alias BeamWeaver.Agent.CapabilityProfile

acme_tuning = CapabilityProfile.new(tool_descriptions: %{"grep" => "Search Acme's policy files for exact text."})
:ok = CapabilityProfile.register_capability_profile("anthropic:claude-sonnet-4-6", acme_tuning)
```

When two profiles merge, the newer or more specific one wins: its prompt texts
replace the others, tool descriptions and middleware merge by tool name and
module, and excluded tools and middleware add up. A model's profile merges
over its provider's the same way, and so does `CapabilityProfile.merge/2`. The
registry is shared by the whole node, so don't register profiles per request.

To keep profiles in a config file or a database, use
`BeamWeaver.Agent.CapabilityProfileConfig`: it holds every field but
middleware, reads string keys, and `to_map/1` turns it back into a map:

```elixir
alias BeamWeaver.Agent.CapabilityProfileConfig

config = CapabilityProfileConfig.from_map(%{"system_prompt_suffix" => "Be brief.", "excluded_tools" => ["execute"]})

CapabilityProfileConfig.to_capability_profile(config).excluded_tools
#=> ["execute"]
```

## The general-purpose subagent

An agent with `subagents` can also hand work to a built-in `general-purpose`
subagent: a fresh copy of the agent with the parent's model, tools, file tools
and skills, a task list of its own, and a generic prompt. A profile's
`general_purpose_subagent` is a `BeamWeaver.Agent.GeneralPurposeSubagentProfile`
with a `description` and a `system_prompt` for it, and `enabled: false` to
leave it out. List it with the subagents to apply it:

```elixir
model "anthropic:claude-sonnet-4-6"

subagents do
  subagent MyApp.PolicyExpert
  include [CapabilityProfile.for_model("anthropic:claude-sonnet-4-6").general_purpose_subagent]
end
```

To change more than its texts, such as its model, declare a subagent named
`"general-purpose"`, which takes the built-in one's place:

```elixir
defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.CapabilityProfile
  alias BeamWeaver.Agent.Subagent
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{"subagent_type" => "general-purpose", "description" => "List refund rules."}),
      "Damaged items get a full refund."
    ]

  subagents [
    Subagent.Spec.new(
      name: "general-purpose",
      description: profile().general_purpose_subagent.description,
      system_prompt: profile().general_purpose_subagent.system_prompt,
      model: BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Damaged items: full refund."])
    )
  ]

  def profile do
    gp = %{description: "Researches one support question.", system_prompt: "Answer in two sentences."}
    CapabilityProfile.new(general_purpose_subagent: gp)
  end
end

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["What is the refund policy?"]})
result.messages |> Enum.find(&(&1.role == :tool)) |> BeamWeaver.Core.Message.text()
#=> "Damaged items: full refund."
```

Your subagent gets only what its spec gives it: without `model:` or `tools:`
it uses the parent's, and `base_middleware: [:deepagents]` adds the built-in
one's task list, file tools and skills. See [Subagents](subagents.md).

## Reference

- [`BeamWeaver.Agent.CapabilityProfile`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.CapabilityProfile.html): profiles, the registry and the built-in profiles
- [`BeamWeaver.Agent.CapabilityProfileConfig`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.CapabilityProfileConfig.html): profiles as plain maps for configuration
- [`BeamWeaver.Agent.GeneralPurposeSubagentProfile`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.GeneralPurposeSubagentProfile.html): settings for the general-purpose subagent
- [`BeamWeaver.Agent.Subagent.Spec`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Subagent.Spec.html): a subagent declared from options
