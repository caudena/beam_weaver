defmodule BeamWeaver.Graph.MessagesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Messages

  describe "add_messages/2 with multiple remove_all markers" do
    test "honors the last remove_all marker" do
      update = [
        Message.user("X", id: "1"),
        Messages.remove_all(),
        Message.user("Y", id: "2"),
        Messages.remove_all(),
        Message.user("Z", id: "3")
      ]

      assert Messages.add_messages([], update) == [Message.user("Z", id: "3")]
    end

    test "agrees with delta_reducer on identical input" do
      update = [
        Message.user("X", id: "1"),
        Messages.remove_all(),
        Message.user("Y", id: "2"),
        Messages.remove_all(),
        Message.user("Z", id: "3")
      ]

      assert Messages.add_messages([], update) == Messages.delta_reducer([], [update])
    end
  end

  describe "format_openai tool call type" do
    test "tags each tool call with the singular tool_call type" do
      message =
        Message.assistant([
          %{"type" => "tool_use", "name" => "search", "input" => %{"q" => "x"}, "id" => "call_1"}
        ])

      [formatted] = Messages.add_messages([], [message], format: :openai)

      assert [%{"type" => "tool_call"} = call] = formatted.tool_calls
      assert call["name"] == "search"
    end
  end
end
