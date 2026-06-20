defmodule BeamWeaver.Core.ChatHistory.ETSTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatHistory
  alias BeamWeaver.Core.Message

  test "concurrent add_messages does not lose appends" do
    store = ChatHistory.ETS.new()
    session = ChatHistory.ETS.for_session(store, "concurrent")

    count = 200

    tasks =
      for index <- 1..count do
        Task.async(fn ->
          ChatHistory.add_messages(session, [Message.user("m#{index}")])
        end)
      end

    Enum.each(tasks, fn task -> assert :ok = Task.await(task) end)

    assert {:ok, messages} = ChatHistory.get_messages(session)
    assert length(messages) == count

    contents = MapSet.new(messages, & &1.content)
    assert MapSet.size(contents) == count
  end
end
