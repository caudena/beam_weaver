defmodule BeamWeaver.Graph.MessagesStateTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Messages

  describe "add_messages/2 behavior" do
    test "adds single and multiple messages" do
      left = [Message.user("Hello", id: "1")]
      right = Message.assistant("Hi there!", id: "2")

      assert Messages.add_messages(left, right) == [
               Message.user("Hello", id: "1"),
               Message.assistant("Hi there!", id: "2")
             ]

      assert Messages.add_messages(left, [
               Message.assistant("Hi there!", id: "2"),
               Message.system("System message", id: "3")
             ]) == [
               Message.user("Hello", id: "1"),
               Message.assistant("Hi there!", id: "2"),
               Message.system("System message", id: "3")
             ]
    end

    test "updates, deduplicates, removes, and removes all by message id" do
      left = [Message.user("Hello", id: "1"), Message.assistant("Hi", id: "2")]

      assert Messages.add_messages(left, Message.user("Hello again", id: "1")) == [
               Message.user("Hello again", id: "1"),
               Message.assistant("Hi", id: "2")
             ]

      assert Messages.add_messages([], [
               Message.assistant("first", id: "1"),
               Message.assistant("second", id: "1")
             ]) == [Message.assistant("second", id: "1")]

      assert Messages.add_messages(left, Messages.remove("2")) == [
               Message.user("Hello", id: "1")
             ]

      assert_raise ArgumentError, ~r/delete a message/, fn ->
        Messages.add_messages(left, Messages.remove("missing"))
      end

      assert Messages.add_messages(left, [Messages.remove_all(), Message.system("new", id: "3")]) ==
               [Message.system("new", id: "3")]
    end

    test "coerces maps, tuples, strings, and assigns UUIDs to missing ids" do
      result =
        Messages.add_messages(
          {"user", "from tuple"},
          [%{"role" => "assistant", "content" => "from map"}, "from string"]
        )

      assert Enum.map(result, & &1.role) == [:user, :assistant, :user]
      assert Enum.map(result, & &1.content) == ["from tuple", "from map", "from string"]

      assert Enum.all?(
               result,
               &Regex.match?(
                 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
                 &1.id
               )
             )
    end

    test "accepts the same roles as Message.from/1" do
      assert [%Message{role: :system, metadata: %{openai_role: :developer}}] =
               Messages.add_messages([], [%{"role" => "developer", "content" => "Be brief."}])

      for role <- ["human", "ai"] do
        assert {:error, %{type: :invalid_role}} = Message.from({role, "hi"})

        assert_raise ArgumentError, ~r/unsupported message representation/, fn ->
          Messages.add_messages([], [%{"role" => role, "content" => "hi"}])
        end

        assert_raise ArgumentError, ~r/unsupported message representation/, fn ->
          Messages.delta_reducer([], [{role, "hi"}])
        end
      end
    end

    test "formats anthropic-style content blocks into OpenAI-compatible messages" do
      result =
        Messages.add_messages(
          [],
          [
            Message.user([
              %{
                "type" => "text",
                "text" => "Here's an image:",
                "cache_control" => %{"type" => "ephemeral"}
              },
              %{
                "type" => "image",
                "source" => %{"type" => "base64", "media_type" => "image/jpeg", "data" => "1234"}
              }
            ]),
            Message.assistant([
              %{"type" => "tool_use", "name" => "foo", "input" => %{"bar" => "baz"}, "id" => "1"}
            ]),
            Message.user([
              %{
                "type" => "tool_result",
                "tool_use_id" => "1",
                "content" => [
                  %{
                    "type" => "image",
                    "source" => %{
                      "type" => "base64",
                      "media_type" => "image/jpeg",
                      "data" => "1234"
                    }
                  }
                ]
              }
            ])
          ],
          format: :openai
        )

      assert [
               %Message{
                 role: :user,
                 content: [
                   %{
                     "type" => "text",
                     "text" => "Here's an image:",
                     "cache_control" => %{"type" => "ephemeral"}
                   },
                   %{
                     "type" => "image_url",
                     "image_url" => %{"url" => "data:image/jpeg;base64,1234"}
                   }
                 ]
               },
               %Message{
                 role: :assistant,
                 content: "",
                 tool_calls: [%{"name" => "foo", "type" => "tool_call", "args" => %{"bar" => "baz"}}]
               },
               %Message{
                 role: :tool,
                 tool_call_id: "1",
                 content: [%ContentBlock.Image{url: "data:image/jpeg;base64,1234"}]
               }
             ] = result
    end
  end

  test "messages state schema merges input and node output through a real graph" do
    graph =
      Graph.new(state_schema: Messages.state_schema())
      |> Graph.add_node(:chatbot, fn _state -> %{messages: [Message.assistant("foo")]} end)
      |> Graph.add_edge(Graph.start(), :chatbot)
      |> Graph.add_edge(:chatbot, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{messages: messages}} =
             Compiled.invoke(graph, %{messages: [{"user", "meow"}]})

    assert Enum.map(messages, & &1.role) == [:user, :assistant]
    assert Enum.map(messages, & &1.content) == ["meow", "foo"]
    assert Enum.all?(messages, &is_binary(&1.id))
  end

  test "a node removes a message from the state by its id" do
    graph =
      Graph.new(state_schema: Messages.state_schema())
      |> Graph.add_node(:forget, fn %{messages: [first | _rest]} ->
        %{messages: [Messages.remove(first.id), Message.assistant("Noted.", id: "a1")]}
      end)
      |> Graph.add_edge(Graph.start(), :forget)
      |> Graph.add_edge(:forget, Graph.end_node())
      |> Graph.compile!()

    input = %{messages: [Message.user("My card is 4111.", id: "u1"), Message.user("Refund A-1001", id: "u2")]}

    assert {:ok, %{messages: messages}} = Compiled.invoke(graph, input)
    assert Enum.map(messages, & &1.id) == ["u2", "a1"]

    # The step's update shows the removal as it was written; the messages
    # stream only carries messages.
    assert {:ok, events} = Compiled.stream_events(graph, input)

    assert [%{"forget" => %{messages: [%Messages.Remove{id: "u1"}, %Message{id: "a1"}]}}] =
             for(%{event: %BeamWeaver.Stream.Events.GraphUpdate{update: update}} <- events, do: update)

    assert ["a1"] =
             for(%{event: %BeamWeaver.Stream.Events.Message{message: message}} <- events, do: message.id)
  end

  test "removing a message that isn't in the state fails the run instead of raising" do
    graph =
      Graph.new(state_schema: Messages.state_schema())
      |> Graph.add_node(:forget, fn _state -> %{messages: [Messages.remove("missing")]} end)
      |> Graph.add_edge(Graph.start(), :forget)
      |> Graph.add_edge(:forget, Graph.end_node())
      |> Graph.compile!()

    assert {:error, %BeamWeaver.Core.Error{type: :invalid_update, message: message}} =
             Compiled.invoke(graph, %{messages: [Message.user("hi", id: "u1")]})

    assert message =~ "does not exist"
  end

  test "delta reducer is batching invariant for message updates and removals" do
    writes = [
      Message.user("hi", id: "h1"),
      Message.assistant("hello", id: "a1"),
      Message.user("updated", id: "h1"),
      Messages.remove("a1")
    ]

    batched = Messages.delta_reducer([], writes)

    split =
      []
      |> Messages.delta_reducer(Enum.take(writes, 2))
      |> Messages.delta_reducer(Enum.drop(writes, 2))

    assert batched == split
    assert batched == [Message.user("updated", id: "h1")]
  end

  test "delta reducer coerces raw state maps and tuple writes without flattening tuples" do
    state = [%{"role" => "user", "content" => "hello", "id" => "h1"}]
    writes = [[%{"role" => "assistant", "content" => "world", "id" => "h1"}]]

    assert [message] = Messages.delta_reducer(state, writes)
    assert message.role == :assistant
    assert message.content == "world"
    assert message.id == "h1"

    assert [tuple_message] = Messages.delta_reducer([], [{"user", "hi"}])
    assert tuple_message.role == :user
    assert tuple_message.content == "hi"
  end

  test "delta reducer replays message removals updates and dict-shaped writes" do
    state =
      []
      |> Messages.delta_reducer([%{"role" => "user", "content" => "hi", "id" => "h1"}])
      |> Messages.delta_reducer([Message.assistant("hello", id: "a1")])

    assert Enum.map(state, & &1.content) == ["hi", "hello"]

    assert [remaining] = Messages.delta_reducer(state, [Messages.remove("a1")])
    assert remaining.content == "hi"

    assert [updated, still_present] =
             Messages.delta_reducer(state, [%{"role" => "assistant", "content" => "world", "id" => "h1"}])

    assert updated.role == :assistant
    assert updated.content == "world"
    assert updated.id == "h1"
    assert still_present.id == "a1"
  end
end
