defmodule BeamWeaver.Agent.Middleware.ToolEmulatorTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.ToolEmulator
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.FakeChatModel

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
