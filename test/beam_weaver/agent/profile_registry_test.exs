defmodule BeamWeaver.Agent.ProfileRegistryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.CapabilityProfile
  alias BeamWeaver.Agent.ProviderProfile

  test "a model id with colons gets its provider's profile and its own" do
    # Keys were split at every colon, so such a model got no profile, not even
    # its provider's, and registering one raised.
    provider = "colons#{System.unique_integer([:positive])}"
    fine_tune = "#{provider}:ft:gpt-5.4-mini:acme::abc123"
    tagged = "#{provider}:glm-5.2:cloud"

    :ok =
      CapabilityProfile.register_capability_profile(
        provider,
        CapabilityProfile.new(prompt_suffix: "Provider tuning.", excluded_tools: ["execute"])
      )

    :ok = CapabilityProfile.register_capability_profile(tagged, CapabilityProfile.new(prompt_suffix: "Tag tuning."))
    :ok = ProviderProfile.register_provider_profile(provider, ProviderProfile.new(init_kwargs: [timeout: 120_000]))

    assert %CapabilityProfile{prompt_suffix: "Provider tuning."} = CapabilityProfile.get_capability_profile(fine_tune)

    assert %CapabilityProfile{prompt_suffix: "Tag tuning.", excluded_tools: ["execute"]} =
             CapabilityProfile.get_capability_profile(tagged)

    assert ProviderProfile.apply_provider_profile(fine_tune, []) == [timeout: 120_000]
  end

  test "a model value whose id has colons gets its provider's profile" do
    # Its id was read as a `provider:model` key, with the id's first part as
    # the provider.
    fine_tune = BeamWeaver.Models.init_chat_model!("openai:ft:gpt-5.4-mini:acme::abc123", api_key: "test")
    assert ProviderProfile.for_model(fine_tune) == ProviderProfile.get_provider_profile("openai")

    provider = "colons#{System.unique_integer([:positive])}"

    :ok =
      CapabilityProfile.register_capability_profile(
        "#{provider}:glm-5.2:cloud",
        CapabilityProfile.new(prompt_suffix: "Tag tuning.")
      )

    assert %CapabilityProfile{prompt_suffix: "Tag tuning."} =
             CapabilityProfile.for_model(%{provider: provider, model_name: "glm-5.2:cloud"})
  end

  test "a key with an empty provider or model is refused" do
    for key <- ["", ":gpt-5.4", "openai:", " openai:gpt-5.4"] do
      assert_raise ArgumentError, fn -> CapabilityProfile.register_capability_profile(key, CapabilityProfile.new()) end
      assert CapabilityProfile.get_capability_profile(key) == nil
    end
  end
end
