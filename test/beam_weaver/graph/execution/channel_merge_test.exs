defmodule BeamWeaver.Graph.Execution.ChannelMergeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Execution.ChannelState
  alias BeamWeaver.Graph.Messages

  test "merge_step_updates folds reducer state through atom and string aliases" do
    original = Message.user("original", id: "m1")
    retry = Message.user("retry", id: "m2")

    assert {:ok, step_update, next_state} =
             ChannelState.merge_step_updates(
               %{"messages" => [original]},
               [%{messages: [retry]}],
               %{messages: &Messages.add_messages/2}
             )

    assert step_update == %{messages: [retry]}
    assert next_state == %{messages: [original, retry]}
  end
end
