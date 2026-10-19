defmodule BeamWeaver.ExamplesSupportTest do
  # examples/support.exs builds the model the live examples run on, from
  # BEAM_WEAVER_EXAMPLES_MODEL.
  use ExUnit.Case, async: false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.TestSupport.ConfigHelper

  Code.require_file("../examples/support.exs", __DIR__)

  alias BeamWeaver.Examples.Support

  test "example options support models with and without reasoning-effort controls" do
    for id <- ["glm-5.1", "glm-5.3"] do
      ConfigHelper.put_config(:examples, model: "zai:#{id}", api_keys: %{"zai" => "test-key"})

      assert {:ok, body} = BeamWeaver.ZAI.ChatModel.request_body(Support.model(), [Message.user("Hi")]),
             "zai:#{id}"

      if id == "glm-5.1" do
        refute Map.has_key?(body, "reasoning_effort"), "zai:#{id}"
      else
        assert body["reasoning_effort"] == "low", "zai:#{id}"
      end
    end
  end
end
