defmodule BeamWeaver.XAI.PreviousResponseTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.OpenAI.Messages, as: OpenAIMessages
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Response
  alias BeamWeaver.XAI.ChatModel
  alias BeamWeaver.XAI.Messages

  defmodule LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up an order by its id."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, _args, _opts), do: {:ok, "Order A-1001 shipped on Monday."}
  end

  # Answers like xAI's Responses API: each reply gets a UUID id and is stored
  # unless the request says `store: false`. Sends each request body to the test
  # and answers with the next scripted `output`.
  defmodule ResponsesTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:xai_request, request.json})
      output = Agent.get_and_update(Keyword.fetch!(opts, :script), fn [next | rest] -> {next, rest} end)

      body = %{
        "id" => uuid(),
        "object" => "response",
        "model" => request.json["model"],
        "status" => "completed",
        "store" => Map.get(request.json, "store", true),
        "output" => output,
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
      }

      {:ok, Response.new(status: 200, headers: [], body: BeamWeaver.JSON.encode!(body))}
    end

    # An id shaped like xAI's, such as "94fa5e70-e18c-9f53-9368-d77dabd2b8a7".
    def uuid do
      <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> =
        16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

      Enum.join([a, b, c, d, e], "-")
    end
  end

  @lookup_call %{
    "type" => "function_call",
    "id" => "fc_1",
    "call_id" => "call_1",
    "name" => "lookup_order",
    "arguments" => ~s({"order_id":"A-1001"}),
    "status" => "completed"
  }

  test "a second turn sends only its new message and continues from xAI's stored reply" do
    model = model(["Noted: order A-1001.", "You mentioned order A-1001."])
    history = [Message.system("You are Acme's support agent."), Message.user("My order is A-1001.")]

    assert {:ok, reply} = CoreChatModel.invoke(model, history, use_previous_response_id: true)
    assert_received {:xai_request, first}
    refute Map.has_key?(first, "previous_response_id")
    assert length(first["input"]) == 2

    # The reply still counts after a checkpoint saves and loads it.
    assert {:ok, saved} = BeamWeaver.Serialization.dump(reply)
    assert {:ok, reply} = BeamWeaver.Serialization.load(saved)

    question = Message.user("Which order did I mention?")
    assert {:ok, answer} = CoreChatModel.invoke(model, history ++ [reply, question], use_previous_response_id: true)
    assert Message.text(answer) == "You mentioned order A-1001."

    assert_received {:xai_request, second}
    assert second["previous_response_id"] == reply.response_metadata.id
    assert second["input"] == [%{"type" => "message", "role" => "user", "content" => "Which order did I mention?"}]
  end

  test "an agent's tool round continues from the reply that called the tool" do
    {:ok, script} = Agent.start_link(fn -> [[@lookup_call], [message("It shipped on Monday.")]] end)

    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: "xai:grok-4.3",
        model_opts: [
          api_key: "test-key",
          transport: ResponsesTransport,
          transport_opts: [parent: self(), script: script],
          use_previous_response_id: true
        ],
        tools: [LookupOrder],
        name: "orders"
      )

    assert {:ok, %{messages: messages}} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001?"]})
    assert Message.text(List.last(messages)) == "It shipped on Monday."

    tool_reply = Enum.find(messages, &(&1.role == :assistant and &1.tool_calls != []))

    assert_received {:xai_request, _first}
    assert_received {:xai_request, second}
    assert second["previous_response_id"] == tool_reply.response_metadata.id
    assert [%{"type" => "function_call_output", "call_id" => "call_1"}] = second["input"]
  end

  test "a reply from another provider, from Chat Completions or not stored is sent, not continued" do
    model = ChatModel.new(model: "grok-4.3")
    xai_reply = responses_reply(%{"id" => ResponsesTransport.uuid()})

    {:ok, openai_reply} =
      OpenAIMessages.response_to_message(%{"id" => "resp_abc", "status" => "completed", "output" => [message("Hi")]})

    {:ok, chat_completions_reply} =
      Messages.chat_completions_to_message(%{
        "id" => ResponsesTransport.uuid(),
        "object" => "chat.completion",
        "model" => "grok-4.3",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hi"}, "finish_reason" => "stop"}]
      })

    unstored_reply = responses_reply(%{"id" => ResponsesTransport.uuid(), "store" => false})

    # After a fallback to another provider, xAI continues from its own last reply.
    assert {:ok, body} =
             ChatModel.request_body(
               model,
               [Message.user("one"), xai_reply, Message.user("two"), openai_reply, Message.user("three")],
               use_previous_response_id: true
             )

    assert body["previous_response_id"] == xai_reply.response_metadata.id

    assert [
             %{"role" => "user", "content" => "two"},
             %{"role" => "assistant", "content" => [%{"text" => "Hi"}]},
             %{"role" => "user", "content" => "three"}
           ] = body["input"]

    for reply <- [openai_reply, chat_completions_reply, unstored_reply] do
      assert {:ok, body} =
               ChatModel.request_body(model, [Message.user("one"), reply, Message.user("two")],
                 use_previous_response_id: true
               )

      refute Map.has_key?(body, "previous_response_id")
      assert length(body["input"]) == 3
    end

    # And OpenAI never continues from xAI's reply.
    assert {:ok, body} =
             BeamWeaver.OpenAI.ChatModel.request_body(
               %BeamWeaver.OpenAI.ChatModel{model: "gpt-5.4-mini"},
               [Message.user("one"), xai_reply, Message.user("two")],
               use_previous_response_id: true
             )

    refute Map.has_key?(body, "previous_response_id")
  end

  test "a streamed reply carries xAI's metadata and can be continued" do
    id = ResponsesTransport.uuid()

    body = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"Noted."}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"#{id}","object":"response","model":"grok-4.3","status":"completed","store":true,"output":[{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Noted."}]}]}}

    data: [DONE]
    """

    model =
      ChatModel.new(
        model: "grok-4.3",
        api_key: "test-key",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/v1/responses"},
          headers: [{"content-type", "text/event-stream"}],
          body: body
        ]
      )

    assert {:ok, events} = CoreChatModel.stream_typed_events(model, [Message.user("My order is A-1001.")])
    assert [reply] = for(%{event: %Events.Message{message: message}} <- Enum.to_list(events), do: message)
    assert %{id: ^id, provider: :xai, model_provider: "xai", api: :responses} = reply.response_metadata

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("My order is A-1001."), reply, Message.user("Which order?")],
               use_previous_response_id: true
             )

    assert body["previous_response_id"] == id
    assert [%{"role" => "user", "content" => "Which order?"}] = body["input"]
  end

  defp model(answers) do
    {:ok, script} = Agent.start_link(fn -> Enum.map(answers, &[message(&1)]) end)

    ChatModel.new(
      model: "grok-4.3",
      api_key: "test-key",
      transport: ResponsesTransport,
      transport_opts: [parent: self(), script: script]
    )
  end

  defp responses_reply(fields) do
    {:ok, reply} =
      Messages.responses_to_message(
        Map.merge(%{"object" => "response", "status" => "completed", "output" => [message("Hi")]}, fields)
      )

    reply
  end

  defp message(text) do
    %{
      "type" => "message",
      "id" => "msg_#{System.unique_integer([:positive])}",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }
  end
end
