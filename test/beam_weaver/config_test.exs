defmodule BeamWeaver.ConfigTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Config

  test "reads grouped application config and treats blank values as missing" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:openai,
      api_key: "sk-config",
      organization: "",
      project: "   "
    )

    assert Config.get([:openai, :api_key]) == "sk-config"
    assert Config.get([:openai, :organization], "default-org") == "default-org"
    assert Config.get([:openai, :project], "default-project") == "default-project"
    assert Config.get([:openai, :missing], "default") == "default"
  end

  test "explicit keyword options including nil win over config defaults" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:openai, api_key: "sk-config")

    assert Config.option([], :api_key, [:openai, :api_key]) == "sk-config"
    assert Config.option([api_key: "sk-explicit"], :api_key, [:openai, :api_key]) == "sk-explicit"
    assert Config.option([api_key: nil], :api_key, [:openai, :api_key]) == nil
  end

  test "group returns configured groups with fallback" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:weave_scope, endpoint: "https://app.weavescope.com")

    assert Config.group(:weave_scope) == [endpoint: "https://app.weavescope.com"]
    assert Config.group(:missing_group, retries: 1) == [retries: 1]
  end
end
