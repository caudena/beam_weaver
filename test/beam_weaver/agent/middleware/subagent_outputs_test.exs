defmodule BeamWeaver.Agent.Middleware.SubagentOutputsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.SubagentOutputs

  describe "before_model/3 response selection" do
    test "uses a configured non-map, non-function response directly" do
      middleware = SubagentOutputs.new(required: [:research], response: "done")
      state = %{subagent_outputs: %{"research" => %{"text" => "x"}}}

      assert {:jump, :end, %{structured_response: "done"}} =
               SubagentOutputs.before_model(middleware, state, %{})
    end

    test "uses a configured map response" do
      middleware = SubagentOutputs.new(required: [:research], response: %{"ok" => true})
      state = %{subagent_outputs: %{"research" => %{}}}

      assert {:jump, :end, %{structured_response: %{"ok" => true}}} =
               SubagentOutputs.before_model(middleware, state, %{})
    end

    test "invokes a configured arity-1 function response" do
      middleware = SubagentOutputs.new(required: [:research], response: fn outputs -> Map.keys(outputs) end)
      state = %{subagent_outputs: %{"research" => %{}}}

      assert {:jump, :end, %{structured_response: ["research"]}} =
               SubagentOutputs.before_model(middleware, state, %{})
    end

    test "falls back to the default response when none is configured" do
      middleware = SubagentOutputs.new(required: [:research])
      state = %{subagent_outputs: %{"research" => %{}}}

      assert {:jump, :end, %{structured_response: %{"status" => "completed", "captured_outputs" => ["research"]}}} =
               SubagentOutputs.before_model(middleware, state, %{})
    end

    test "does not jump until all required outputs are present" do
      middleware = SubagentOutputs.new(required: [:research, :review], response: "done")
      state = %{subagent_outputs: %{"research" => %{}}}

      assert %{} == SubagentOutputs.before_model(middleware, state, %{})
    end
  end
end
