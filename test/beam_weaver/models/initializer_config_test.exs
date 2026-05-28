defmodule BeamWeaver.Models.InitializerConfigTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Models

  test "init_chat_model applies configured provider API keys" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:google, api_key: "google-config-secret")
    BeamWeaver.TestSupport.ConfigHelper.put_config(:openai, api_key: "openai-config-secret")

    assert {:ok, google} = Models.init_chat_model("google:gemini-3.5-flash")
    assert google.api_key == "google-config-secret"

    assert {:ok, openai} = Models.init_chat_model("openai:gpt-5.4")
    assert openai.api_key == "openai-config-secret"
  end

  test "init_chat_model keeps explicit nil API keys explicit" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:google, api_key: "google-config-secret")

    assert {:ok, google} = Models.init_chat_model("google:gemini-3.5-flash", api_key: nil)
    assert google.api_key == nil
  end
end
