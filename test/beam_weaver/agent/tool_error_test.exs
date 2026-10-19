defmodule BeamWeaver.Agent.ToolErrorTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.ToolError
  alias BeamWeaver.Agent.Middleware.ToolRetry
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models.FakeChatModel

  # Its database errors carry details the model shouldn't see.
  defp lookup_order do
    parent = self()

    Tool.from_function!(
      name: "lookup_order",
      description: "Look up an order",
      input_schema: %{"type" => "object", "properties" => %{"order_id" => %{"type" => "string"}}},
      handler: fn %{"order_id" => order_id}, _opts ->
        send(parent, {:lookup, order_id})
        {:error, Error.new(:db_timeout, "SELECT * FROM orders timed out on db-7.internal")}
      end
    )
  end

  defp run(args, middleware) do
    {:ok, agent} =
      BeamWeaver.Agent.build(
        model:
          BeamWeaver.Models.init_chat_model!("fake:chat",
            responses: [FakeChatModel.tool_call("lookup_order", args), "Please try later."]
          ),
        tools: [lookup_order()],
        middleware: middleware
      )

    BeamWeaver.Agent.invoke(agent, %{messages: ["Where is my order?"]})
  end

  defp tool_message({:ok, result}), do: Enum.find(result.messages, &match?(%Message{role: :tool}, &1))

  defp on_error(%Error{type: :db_timeout}, request),
    do: "#{request.tool_call.name} is unavailable right now; ask the customer to try again later."

  defp on_error(%Error{}, _request), do: nil

  test "the model reads what on_error returns instead of the tool's error" do
    message = tool_message(run(%{"order_id" => "A-1"}, [{ToolError, on_error: &on_error/2}]))

    assert Message.text(message) == "lookup_order is unavailable right now; ask the customer to try again later."
    assert %{status: "error", error_type: :db_timeout} = message.metadata
  end

  test "nil stops the run with the error" do
    assert {:error, %Error{type: :db_timeout}} =
             run(%{"order_id" => "A-1"}, [{ToolError, on_error: fn _error, _request -> nil end}])
  end

  test "arguments the model got wrong reach it as they are" do
    message = tool_message(run(%{"order_id" => 1001}, [{ToolError, on_error: fn _error, _request -> nil end}]))

    assert %{error_type: :invalid_input} = message.metadata
    assert Message.text(message) =~ "Tool error:"
    refute_received {:lookup, _order_id}
  end

  test ":tools limits it to the named tools" do
    message =
      tool_message(
        run(%{"order_id" => "A-1"}, [{ToolError, on_error: fn _error, _request -> nil end, tools: ["refund"]}])
      )

    assert Message.text(message) =~ "Tool error: SELECT * FROM orders timed out"
  end

  # ToolRetry listed after it retries first; ToolError gets the last failure.
  test "gets the last failure of a ToolRetry listed after it" do
    middleware = [{ToolError, on_error: &on_error/2}, {ToolRetry, retry_on: :db_timeout}]
    message = tool_message(run(%{"order_id" => "A-1"}, middleware))

    assert Message.text(message) =~ "unavailable right now"
    assert_received {:lookup, "A-1"}
    assert_received {:lookup, "A-1"}
    assert_received {:lookup, "A-1"}
  end

  test "on_error is required" do
    assert_raise ArgumentError, ~r/needs :on_error/, fn -> ToolError.new([]) end
  end
end
