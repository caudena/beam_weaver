defmodule BeamWeaver.Graph.ErrorsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Errors

  test "graph error codes and messages use tagged BeamWeaver errors" do
    assert Errors.error_codes().recursion_limit == "GRAPH_RECURSION_LIMIT"

    message = Errors.create_message("too many steps", :recursion_limit)
    assert message =~ "too many steps"
    assert message =~ "/langgraph/errors/GRAPH_RECURSION_LIMIT"

    assert %Error{
             type: :recursion_limit,
             details: %{limit: 3, step: 3, code: "GRAPH_RECURSION_LIMIT"}
           } = Errors.recursion_limit(3, 3)

    assert %Error{
             type: :invalid_update,
             details: %{channel: :messages, code: "INVALID_CONCURRENT_GRAPH_UPDATE"}
           } = Errors.invalid_concurrent_update(%{channel: :messages})
  end

  test "exception-like graph conditions are represented as tagged errors" do
    assert %Error{type: :graph_interrupt, details: %{interrupts: [:pause]}} =
             Errors.graph_interrupt(:pause)

    assert %Error{type: :graph_drained, message: "graph drained: shutdown"} =
             Errors.graph_drained()

    assert %Error{type: :parent_command, details: %{command: %{goto: :parent}}} =
             Errors.parent_command(%{goto: :parent})

    assert %Error{type: :task_not_found, details: %{task_id: "task-1"}} =
             Errors.task_not_found("task-1")

    error = Error.new(:node_failed, "boom")

    assert %Error{type: :node_error, details: %{node: "worker", error: ^error}} =
             Errors.node_error(:worker, error)
  end

  test "node timeout helper preserves timeout context" do
    assert %Error{
             type: :node_timeout,
             message: idle_message,
             details: %{
               node: "worker",
               elapsed: 1.25,
               kind: :idle,
               idle_timeout: 1.0,
               run_timeout: 5.0,
               timeout: 1.0
             }
           } =
             Errors.node_timeout(:worker, 1.25, kind: :idle, idle_timeout: 1.0, run_timeout: 5.0)

    assert idle_message =~ "idle timeout"
    assert idle_message =~ "1.000s"

    assert %Error{
             type: :node_timeout,
             message: run_message,
             details: %{kind: :run, timeout: 2.0}
           } = Errors.node_timeout("worker", 2.5, %{"kind" => "run", "run_timeout" => 2.0})

    assert run_message =~ "run timeout"
  end
end
