defmodule BeamWeaver.Agent.ToolRetryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.ToolRetry
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.FakeChatModel

  defmodule LookupOrder do
    use BeamWeaver.Tool

    alias BeamWeaver.Core.Error

    name "lookup_order"
    description "Look up an order."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, %{"order_id" => "Z-" <> _}, _opts),
      do: {:error, Error.new(:timeout, "The archive service timed out")}

    def invoke(_tool, %{"order_id" => order_id}, _opts),
      do: {:error, Error.new(:not_found, "No order #{order_id}.")}
  end

  defmodule ContinueAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [FakeChatModel.tool_call("lookup_order", %{"order_id" => "Z-0042"}), "Sorry, try later."]

    tools [LookupOrder]
    middleware [{ToolRetry, retry_on: :timeout, on_failure: :continue}]
  end

  defmodule ErrorAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [FakeChatModel.tool_call("lookup_order", %{"order_id" => "Z-0042"}), "Sorry, try later."]

    tools [LookupOrder]
    middleware [{ToolRetry, retry_on: :timeout}]
  end

  defmodule NotRetriedAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-9999"}), "No such order."]

    tools [LookupOrder]
    middleware [{ToolRetry, retry_on: :timeout, on_failure: :continue}]
  end

  defp tool_text(module) do
    assert {:ok, result} = module.invoke(%{messages: ["Where is my order?"]})
    result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
  end

  test "the :continue message names the tool's error once" do
    assert tool_text(ContinueAgent) ==
             "Tool 'lookup_order' failed after 3 attempts with timeout: The archive service timed out. Please try again."
  end

  test "with on_failure: :error the model gets the tool's last error as is" do
    assert tool_text(ErrorAgent) == ~s(Tool error: The archive service timed out. Args: %{"order_id" => "Z-0042"})
  end

  test "the message counts the attempts made and keeps one period" do
    assert tool_text(NotRetriedAgent) ==
             "Tool 'lookup_order' failed after 1 attempt with not_found: No order A-9999. Please try again."
  end
end
