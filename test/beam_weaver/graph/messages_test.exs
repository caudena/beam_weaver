defmodule BeamWeaver.Graph.MessagesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Messages

  test "add_messages/2 and delta_reducer/2 honor the last of several remove_all markers" do
    update = [
      Message.user("X", id: "1"),
      Messages.remove_all(),
      Message.user("Y", id: "2"),
      Messages.remove_all(),
      Message.user("Z", id: "3")
    ]

    assert Messages.add_messages([], update) == [Message.user("Z", id: "3")]
    assert Messages.delta_reducer([], [update]) == [Message.user("Z", id: "3")]
  end
end
