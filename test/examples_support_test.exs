defmodule BeamWeaver.ExamplesSupportTest do
  # examples/support.exs builds the model the live examples run on, from
  # BEAM_WEAVER_EXAMPLES_MODEL.
  use ExUnit.Case, async: false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.TestSupport.ConfigHelper

  Code.require_file("../examples/support.exs", __DIR__)

  alias BeamWeaver.Examples.Support

  test "every Z.ai model takes the examples' options; those that take it think at low effort" do
    for profile <- ProfileRegistry.profiles(:zai) do
      ConfigHelper.put_config(:examples, model: "zai:#{profile.id}", api_keys: %{"zai" => "test-key"})

      assert {:ok, body} = BeamWeaver.ZAI.ChatModel.request_body(Support.model(), [Message.user("Hi")]),
             "zai:#{profile.id}"

      if profile.id in ["glm-5.1", "glm-5", "glm-4.7", "glm-4.6"] do
        refute Map.has_key?(body, "reasoning_effort"), "zai:#{profile.id}"
      else
        assert body["reasoning_effort"] == "low", "zai:#{profile.id}"
      end
    end
  end
end
