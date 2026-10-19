defmodule BeamWeaver.Agent.Middleware.ToolEmulatorTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.ToolEmulator
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.FakeChatModel

  defmodule LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up an order."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, _input, _opts), do: "real"
  end

  test "emulates the calls of a tool given as a module" do
    middleware =
      ToolEmulator.new(tools: [LookupOrder], model: %FakeChatModel{response: Message.assistant("emulated")})

    request = %ToolCallRequest{tool_call: %{id: "call_1", name: "lookup_order", args: %{"order_id" => "A-1"}}}

    assert %Message{content: "emulated", name: "lookup_order", metadata: %{emulated?: true}} =
             ToolEmulator.wrap_tool_call(middleware, request, fn _ -> Message.tool("real") end)

    other = %ToolCallRequest{tool_call: %{id: "call_2", name: "other", args: %{}}}
    assert %Message{content: "real"} = ToolEmulator.wrap_tool_call(middleware, other, fn _ -> Message.tool("real") end)
  end

  test "emulates a tool call whose tool_call has no name without crashing" do
    middleware =
      ToolEmulator.new(model: %FakeChatModel{response: Message.assistant("emulated")})

    request = %ToolCallRequest{tool_call: %{id: "call_1", args: %{"foo" => "bar"}}}

    assert %Message{
             role: :tool,
             content: "emulated",
             tool_call_id: "call_1",
             name: "unknown_tool",
             metadata: %{emulated?: true}
           } = ToolEmulator.wrap_tool_call(middleware, request, fn _ -> Message.tool("real") end)
  end

  test "emulates a tool call whose tool_call is nil without crashing" do
    middleware =
      ToolEmulator.new(model: %FakeChatModel{response: Message.assistant("emulated")})

    request = %ToolCallRequest{tool_call: nil}

    assert %Message{
             role: :tool,
             name: "unknown_tool",
             metadata: %{emulated?: true}
           } = ToolEmulator.wrap_tool_call(middleware, request, fn _ -> Message.tool("real") end)
  end
end
