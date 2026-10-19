Code.require_file("../scripts/examples/live_runner.exs", __DIR__)
Code.require_file("../examples/support.exs", __DIR__)

defmodule BeamWeaver.ExamplesLiveVerificationTest do
  use ExUnit.Case, async: false
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Examples.Support

  test "a successful process without a real provider response fails live verification" do
    job = %{script: "examples/basic_graph.exs", provider: :openai, model: "openai:gpt-5.4-mini", args: []}
    result = BeamWeaver.Examples.LiveRunner.verify_job(job, System.get_env(), 30_000)
    assert result.status == :fail
    assert result.evidence["successful_inference_requests"] == 0
    assert result.evidence["missing_providers"] == ["openai"]
  end

  test "tool verification requires a successful result with the requested arguments" do
    call = %{id: "lookup-1", name: "lookup_order", args: %{"order_id" => "A-1001"}}
    requested = Message.assistant("", tool_calls: [call])
    expected = [{"lookup_order", %{"order_id" => "A-1001"}}]

    for result <- [
          nil,
          Message.tool("failed", tool_call_id: "lookup-1", status: :error),
          Message.tool("failed", tool_call_id: "lookup-1", metadata: %{status: "error"})
        ] do
      assert_raise RuntimeError, ~r/expected successful execution/, fn ->
        Support.assert_tools_called!(Enum.reject([requested, result], &is_nil/1), expected)
      end
    end

    completed = [requested, Message.tool("Shipped", tool_call_id: "lookup-1")]
    assert Support.assert_tools_called!(completed, expected) == ["lookup_order"]

    assert_raise RuntimeError, fn ->
      Support.assert_tools_called!(completed, [{"lookup_order", %{"order_id" => "A-1002"}}])
    end
  end
end
