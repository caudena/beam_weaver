defmodule BeamWeaver.Anthropic.StreamReplyTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Response

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

  # Answers each request with the next scripted reply, streamed or not, and
  # sends the request's JSON to the test. A binary is sent as the stream.
  defmodule Scripted do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:request, request.json})
      reply = Agent.get_and_update(Keyword.fetch!(opts, :script), fn [next | rest] -> {next, rest} end)

      {content_type, body} =
        cond do
          is_binary(reply) -> {"text/event-stream", reply}
          request.json["stream"] == true -> {"text/event-stream", BeamWeaver.Anthropic.StreamReplyTest.sse(reply)}
          true -> {"application/json", BeamWeaver.JSON.encode!(reply)}
        end

      {:ok,
       Response.new(
         status: 200,
         headers: [{"content-type", content_type}, {"request-id", "req_1"}],
         body: body
       )}
    end
  end

  @thinking %{"type" => "thinking", "thinking" => "The order needs a lookup.", "signature" => "sig_1"}
  @lookup %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup_order", "input" => %{"order_id" => "A-1001"}}

  test "a typed stream ends with the reply a call without streaming returns, then Done" do
    reply = message("msg_1", [@thinking, %{"type" => "text", "text" => "Let me check."}, @lookup], "tool_use")
    model = model(script: [reply, reply])

    assert {:ok, invoked} = model.__struct__.invoke(model, [Message.user("Where is order A-1001?")])
    assert {:ok, stream} = ChatModel.stream_typed_events(model, [Message.user("Where is order A-1001?")])

    assert [%Events.Message{message: streamed}, %Events.Done{}] =
             for(%{event: %type{} = event} <- Enum.to_list(stream), type in [Events.Message, Events.Done], do: event)

    assert streamed.content == invoked.content
    assert streamed.tool_calls == invoked.tool_calls
    assert streamed.usage_metadata == invoked.usage_metadata
    assert streamed.usage_metadata == %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
    assert streamed.status == "tool_use"
    assert streamed.id == "msg_1"

    for key <- [:model_provider, :id, :model, :stop_reason, :usage, :request_id, :headers] do
      assert Map.fetch!(streamed.response_metadata, key) == Map.fetch!(invoked.response_metadata, key)
    end
  end

  test "a streaming agent keeps the reply's usage and metadata and sends its thinking back with the tool result" do
    {:ok, agent} =
      BeamWeaver.Agent.build(
        name: "orders",
        model: "anthropic:claude-haiku-4-5",
        model_opts:
          model_opts(
            script: [
              message("msg_1", [@thinking, @lookup], "tool_use"),
              message("msg_2", [%{"type" => "text", "text" => "It shipped on Monday."}], "end_turn")
            ],
            stream: true,
            thinking: %{type: :enabled, budget_tokens: 1_024}
          ),
        tools: [LookupOrder]
      )

    assert {:ok, %{messages: messages}} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001?"]})

    assert_received {:request, %{"stream" => true}}
    assert_received {:request, second}
    assert [_user, %{"role" => "assistant", "content" => content}, _tool_result] = second["messages"]
    assert content == [@thinking, @lookup]

    [tool_round, answer] = Enum.filter(messages, &(&1.role == :assistant))
    assert [%{type: :reasoning, reasoning: "The order needs a lookup."}, %{type: :tool_call}] = tool_round.content
    assert Message.text(answer) == "It shipped on Monday."

    for reply <- [tool_round, answer] do
      assert reply.usage_metadata == %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
      assert reply.response_metadata.model_provider == "anthropic"
      assert reply.response_metadata.request_id == "req_1"
    end
  end

  test "a typed stream cut off by an error event ends with that error, not the reply so far" do
    model = model(script: [cut_off("overloaded_error", "Overloaded")])

    assert {:ok, stream} = ChatModel.stream_typed_events(model, [Message.user("Where is order A-1001?")])
    envelopes = Enum.to_list(stream)
    assert Enum.all?(envelopes, &is_struct(&1, Envelope))
    events = Enum.map(envelopes, & &1.event)

    assert for(%Events.Token{text: text} <- events, do: text) == ["It shipped on"]
    assert [%Events.Error{error: %Error{type: :http_error, message: "Overloaded"} = error}] = errors(events)
    refute Enum.any?(events, &(is_struct(&1, Events.Message) or is_struct(&1, Events.Done)))

    assert error.details.status == 529
    assert error.details.error_type == "overloaded_error"
    assert error.details.retryable
    assert error.details.request_id == "req_1"
  end

  test "stream_response/3 and a text stream return the error instead of the reply so far" do
    model = model(script: [cut_off("overloaded_error", "Overloaded"), cut_off("overloaded_error", "Overloaded")])

    assert {:error, %Error{type: :http_error, message: "Overloaded", details: %{status: 529}}} =
             model.__struct__.stream_response(model, [Message.user("Where is order A-1001?")])

    assert {:ok, stream} = ChatModel.stream(model, [Message.user("Where is order A-1001?")])
    assert ["It shipped on", %Events.Error{error: %Error{details: %{status: 529}}}] = Enum.to_list(stream)
  end

  test "an error event is classified like the same error without streaming" do
    for {type, message, error_type, status, retryable?} <- [
          {"rate_limit_error", "Number of request tokens has exceeded your rate limit", :http_error, 429, true},
          {"api_error", "Internal server error", :http_error, 500, true},
          {"invalid_request_error", "prompt is too long: 210000 tokens > 200000 maximum", :context_overflow, 400, false}
        ] do
      model = model(script: [cut_off(type, message)])

      assert {:error, %Error{} = error} = model.__struct__.stream_response(model, [Message.user("Hi")])
      assert {error.type, error.message, error.details.status} == {error_type, message, status}
      assert error.details.retryable == retryable?
      assert BeamWeaver.RetryPredicates.transient?(error) == retryable?
    end
  end

  test "a streaming agent returns the error of a stream cut off partway" do
    {:ok, agent} =
      BeamWeaver.Agent.build(
        name: "orders",
        model: "anthropic:claude-haiku-4-5",
        model_opts: model_opts(script: [cut_off("overloaded_error", "Overloaded")], stream: true)
      )

    assert {:error, %Error{type: :http_error, message: "Overloaded", details: %{status: 529}}} =
             BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001?"]})
  end

  test "a streaming agent with ModelRetry retries a stream cut off by an overloaded error" do
    {:ok, agent} =
      BeamWeaver.Agent.build(
        name: "orders",
        model: "anthropic:claude-haiku-4-5",
        model_opts:
          model_opts(
            script: [
              cut_off("overloaded_error", "Overloaded"),
              message("msg_2", [%{"type" => "text", "text" => "It shipped on Monday."}], "end_turn")
            ],
            stream: true
          ),
        middleware: [{BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 1}]
      )

    assert {:ok, %{messages: messages}} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001?"]})

    assert_received {:request, %{"stream" => true}}
    assert_received {:request, %{"stream" => true}}
    assert [answer] = Enum.filter(messages, &(&1.role == :assistant))
    assert Message.text(answer) == "It shipped on Monday."
  end

  # The SSE stream Anthropic sends for a reply.
  def sse(reply), do: encode(stream_events(reply))

  # A stream Anthropic cuts off after the start of the answer with an `error`
  # event, which it sends after the 200 response instead of an HTTP error.
  defp cut_off(type, message) do
    events = message("msg_1", [%{"type" => "text", "text" => "It shipped on"}], nil) |> stream_events() |> Enum.take(3)
    encode(events ++ [%{"type" => "error", "error" => %{"type" => type, "message" => message}}])
  end

  defp stream_events(%{"content" => content} = reply) do
    message = %{reply | "content" => [], "stop_reason" => nil, "usage" => %{"input_tokens" => 10}}
    start = %{"type" => "message_start", "message" => message}

    blocks =
      content
      |> Enum.with_index()
      |> Enum.flat_map(fn {block, index} -> block_events(block, index) end)

    finish = [
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => reply["stop_reason"], "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 5}
      },
      %{"type" => "message_stop"}
    ]

    [start | blocks] ++ finish
  end

  defp encode(events), do: Enum.map_join(events, &"event: #{&1["type"]}\ndata: #{BeamWeaver.JSON.encode!(&1)}\n\n")

  defp errors(events), do: Enum.filter(events, &is_struct(&1, Events.Error))

  defp block_events(%{"type" => "thinking"} = block, index) do
    [
      start(index, %{"type" => "thinking", "thinking" => "", "signature" => ""}),
      delta(index, %{"type" => "thinking_delta", "thinking" => block["thinking"]}),
      delta(index, %{"type" => "signature_delta", "signature" => block["signature"]}),
      stop(index)
    ]
  end

  defp block_events(%{"type" => "text"} = block, index) do
    [
      start(index, %{"type" => "text", "text" => ""}),
      delta(index, %{"type" => "text_delta", "text" => block["text"]}),
      stop(index)
    ]
  end

  defp block_events(%{"type" => "tool_use"} = block, index) do
    [
      start(index, %{block | "input" => %{}}),
      delta(index, %{"type" => "input_json_delta", "partial_json" => BeamWeaver.JSON.encode!(block["input"])}),
      stop(index)
    ]
  end

  defp start(index, block), do: %{"type" => "content_block_start", "index" => index, "content_block" => block}
  defp delta(index, delta), do: %{"type" => "content_block_delta", "index" => index, "delta" => delta}
  defp stop(index), do: %{"type" => "content_block_stop", "index" => index}

  defp message(id, content, stop_reason) do
    %{
      "id" => id,
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5",
      "content" => content,
      "stop_reason" => stop_reason,
      "stop_sequence" => nil,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
  end

  defp model(opts), do: BeamWeaver.Models.init_chat_model!("anthropic:claude-haiku-4-5", model_opts(opts))

  defp model_opts(opts) do
    {:ok, script} = Agent.start_link(fn -> Keyword.fetch!(opts, :script) end)

    opts
    |> Keyword.delete(:script)
    |> Keyword.merge(api_key: "k", transport: Scripted, transport_opts: [parent: self(), script: script])
  end
end
