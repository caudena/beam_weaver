defmodule BeamWeaver.XAI.ReasoningReplayTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
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

  # Answers each request with the next scripted Responses `output` and sends the
  # request body to the test.
  defmodule ScriptedTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:xai_request, request.json})
      output = Agent.get_and_update(Keyword.fetch!(opts, :script), fn [next | rest] -> {next, rest} end)

      body = %{
        "id" => "#{System.unique_integer([:positive])}",
        "model" => request.json["model"],
        "status" => "completed",
        "output" => output,
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
      }

      {:ok, Response.new(status: 200, headers: [], body: BeamWeaver.JSON.encode!(body))}
    end
  end

  @reasoning %{
    "type" => "reasoning",
    "id" => "rs_1",
    "summary" => [%{"type" => "summary_text", "text" => "Look the order up."}],
    "status" => "completed",
    "encrypted_content" => "encrypted-thinking"
  }

  @lookup_call %{
    "type" => "function_call",
    "id" => "fc_1",
    "call_id" => "call_1",
    "name" => "lookup_order",
    "arguments" => ~s({"order_id":"A-1001"}),
    "status" => "completed"
  }

  @answer %{
    "type" => "message",
    "id" => "msg_1",
    "role" => "assistant",
    "status" => "completed",
    "content" => [%{"type" => "output_text", "text" => "It shipped on Monday.", "annotations" => []}]
  }

  test "an agent on a reasoning model asks for encrypted reasoning and sends it back unchanged" do
    {:ok, script} = Agent.start_link(fn -> [[@reasoning, @lookup_call], [@answer]] end)

    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: "xai:grok-4.20-0309-reasoning",
        model_opts: [
          api_key: "test-key",
          transport: ScriptedTransport,
          transport_opts: [parent: self(), script: script]
        ],
        tools: [LookupOrder],
        name: "orders"
      )

    assert {:ok, %{messages: messages}} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001?"]})
    assert Message.text(List.last(messages)) == "It shipped on Monday."

    assert_received {:xai_request, first}
    assert first["include"] == ["reasoning.encrypted_content"]

    assert_received {:xai_request, second}
    assert second["include"] == ["reasoning.encrypted_content"]

    assert [
             %{"type" => "message", "role" => "user"},
             @reasoning,
             %{"type" => "function_call", "call_id" => "call_1", "name" => "lookup_order"},
             %{"type" => "function_call_output", "call_id" => "call_1"}
           ] = second["input"]
  end

  test "the caller's include list keeps its entries, and extra_body replaces it" do
    model = ChatModel.new(model: "grok-4.20-0309-reasoning")

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("search")], include: ["web_search_call.action.sources"])

    assert body["include"] == ["web_search_call.action.sources", "reasoning.encrypted_content"]

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("search")], include: ["reasoning.encrypted_content"])

    assert body["include"] == ["reasoning.encrypted_content"]

    assert {:ok, body} = ChatModel.request_body(model, [Message.user("search")], extra_body: %{include: []})
    assert body["include"] == []
  end

  test "a non-reasoning model gets no include" do
    model = ChatModel.new(model: "grok-4.20-0309-non-reasoning")

    assert {:ok, body} = ChatModel.request_body(model, [Message.user("hi")])
    refute Map.has_key?(body, "include")
  end

  test "a reply's encrypted reasoning survives decoding and is replayed after store: false drops the ids" do
    assert {:ok, reply} =
             Messages.responses_to_message(%{
               "id" => "resp-1",
               "status" => "completed",
               "output" => [@reasoning, @lookup_call]
             })

    tool_result = Message.tool("Order A-1001 shipped on Monday.", tool_call_id: "call_1")

    assert {:ok, body} =
             ChatModel.request_body(
               ChatModel.new(model: "grok-4.20-0309-reasoning", store: false),
               [Message.user("Where is order A-1001?"), reply, tool_result]
             )

    assert body["store"] == false
    assert Enum.find(body["input"], &(&1["type"] == "reasoning")) == Map.delete(@reasoning, "id")
  end
end
