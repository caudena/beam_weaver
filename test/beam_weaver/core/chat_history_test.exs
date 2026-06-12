defmodule BeamWeaver.Core.ChatHistoryTest do
  use ExUnit.Case, async: true

  # Upstream reference:

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.ChatHistory
  alias BeamWeaver.Core.ChatLoader
  alias BeamWeaver.Core.ChatSession
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  defmodule FixtureChatLoader do
    @behaviour ChatLoader

    defstruct sessions: []

    @impl true
    def lazy_load(%__MODULE__{sessions: sessions}) do
      Stream.map(sessions, & &1)
    end
  end

  test "ETS chat history appends messages in order and clears a session" do
    store = ChatHistory.ETS.new()
    session = ChatHistory.ETS.for_session(store, "session-1")

    assert {:ok, []} = ChatHistory.get_messages(session)

    assert :ok = ChatHistory.add_messages(session, [Message.user("hello")])
    assert :ok = ChatHistory.add_messages(session, [Message.assistant("world")])

    assert {:ok, [%Message{content: "hello"}, %Message{content: "world"}]} =
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

  test "async chat history helpers use Task-backed public calls" do
    store = ChatHistory.ETS.new()
    session = ChatHistory.ETS.for_session(store, "async")

    assert :ok =
             ChatHistory.async_add_messages(session, [
               Message.user("hello"),
               Message.assistant("world")
             ])
             |> Async.await()

    assert {:ok, [%Message{content: "hello"}, %Message{content: "world"}]} =
             ChatHistory.async_get_messages(session) |> Async.await()

    assert :ok = ChatHistory.async_clear(session) |> Async.await()
    assert {:ok, []} = ChatHistory.get_messages(session)
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

  test "chat sessions and chat loaders normalize lazy sessions into eager native structs" do
    assert {:ok, session} =
             ChatSession.new(
               messages: [{"human", "hello"}, Message.assistant("hi")],
               functions: [%{"name" => "lookup"}]
             )

    assert [%Message{role: :user}, %Message{role: :assistant}] = session.messages
    assert ChatSession.to_map(session).functions == [%{"name" => "lookup"}]

    loader =
      %FixtureChatLoader{
        sessions: [
          session,
          %{messages: [{"human", "next"}], functions: []}
        ]
      }

    assert {:ok, lazy} = ChatLoader.lazy_load(loader)
    assert [%ChatSession{}, %ChatSession{}] = Enum.to_list(lazy)

    assert {:ok, [%ChatSession{} = first, %ChatSession{} = second]} = ChatLoader.load(loader)
    assert Message.text(List.first(first.messages)) == "hello"
    assert Message.text(List.first(second.messages)) == "next"
  end
end
