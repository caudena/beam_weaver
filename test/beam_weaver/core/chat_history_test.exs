defmodule BeamWeaver.Core.ChatHistoryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatHistory
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  test "ETS chat history appends messages in order and clears a session" do
    store = ChatHistory.ETS.new()
    session = ChatHistory.ETS.for_session(store, "session-1")

    assert {:ok, []} = ChatHistory.get_messages(session)

    assert :ok = ChatHistory.add_messages(session, [Message.user("hello")])
    assert :ok = ChatHistory.add_messages(session, [Message.assistant("world"), Message.user("again")])

    assert {:ok, [%Message{content: "hello"}, %Message{content: "world"}, %Message{content: "again"}]} =
             ChatHistory.get_messages(session)

    assert :ok = ChatHistory.clear(session)
    assert {:ok, []} = ChatHistory.get_messages(session)
  end

  test "ETS chat history isolates sessions by normalized session id" do
    store = ChatHistory.ETS.new()
    numeric_session = ChatHistory.ETS.for_session(store, 123)
    string_session = ChatHistory.ETS.for_session(store, "123")
    other_session = ChatHistory.ETS.for_session(store, "other")

    assert :ok = ChatHistory.add_messages(numeric_session, [Message.user("same")])

    assert {:ok, [%Message{content: "same"}]} = ChatHistory.get_messages(string_session)
    assert {:ok, []} = ChatHistory.get_messages(other_session)
  end

  test "convenience append helpers build user and assistant messages" do
    store = ChatHistory.ETS.new()
    session = ChatHistory.ETS.for_session(store, "helpers")

    assert :ok = ChatHistory.add_user_message(session, "hello", id: "u1")
    assert :ok = ChatHistory.add_ai_message(session, "world", id: "a1")

    assert {:ok, [%Message{role: :user, id: "u1"}, %Message{role: :assistant, id: "a1"}]} =
             ChatHistory.get_messages(session)
  end

  test "history renders a role buffer string" do
    store = ChatHistory.ETS.new()
    session = ChatHistory.ETS.for_session(store, "buffer")

    assert :ok =
             ChatHistory.add_messages(session, [Message.user("hello"), Message.assistant("hi")])

    assert {:ok, "Human: hello\nAI: hi"} = ChatHistory.buffer_string(session)
  end

  test "memory-backed chat history uses the explicit memory store contract" do
    store = BeamWeaver.Memory.ETS.new()

    history =
      ChatHistory.Memory.new(
        store: store,
        namespace: ["sessions"],
        metadata: %{source: "history"}
      )

    session = ChatHistory.Memory.for_session(history, :abc)

    assert :ok = ChatHistory.add_messages(session, [Message.user("persisted")])

    assert {:ok, [%Message{content: "persisted"}]} = ChatHistory.get_messages(session)

    assert {:ok, item} = BeamWeaver.Memory.get(store, ["sessions"], "abc")
    assert item.metadata == %{source: "history"}

    assert :ok = ChatHistory.clear(session)
    assert {:ok, []} = ChatHistory.get_messages(session)
  end

  test "unsupported history sources return tagged errors" do
    assert {:error, %Error{type: :unsupported_chat_history}} =
             ChatHistory.get_messages(%{})
  end
end
