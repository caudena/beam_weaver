defmodule BeamWeaver.Google.StreamingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Google.ChatModel
  alias BeamWeaver.Google.Messages
  alias BeamWeaver.Provider.Replay
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Response

  defmodule Transport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(_request, _opts), do: raise("unexpected non-streaming request")

    @impl true
    def stream_reduce(request, opts, acc, reducer) do
      send(Keyword.fetch!(opts, :parent), {:stream_request, self(), request})
      {chunks, result} = Keyword.fetch!(opts, :respond).(request)

      acc =
        Enum.reduce(chunks, acc, fn
          :await_consumer, acc ->
            receive do
              :continue -> acc
            after
              2_000 -> raise "live event was not delivered before transport completion"
            end

          chunk, acc ->
            reducer.(acc, chunk)
        end)

      case result do
        {:ok, response} -> {:ok, response, acc}
        {:error, error} -> {:error, error, acc}
      end
    end
  end

  test "tool-only stream emits live calls and exactly one decoded message before Done" do
    part = call_part("call-ping", "ping")
    responses = [candidate([part], false), terminal(), usage()]
    [first | rest] = Enum.map(responses, &sse/1)
    model = model(fn _ -> {[first, :await_consumer | rest], ok_response()} end)

    assert {:ok, stream} =
             CoreChatModel.stream_typed_events(model, [Message.user("Ping")],
               tools: [tool()],
               tool_choice: :required
             )

    events =
      Enum.map(stream, fn envelope ->
        event = unwrap(envelope)

        if match?(%Events.Custom{payload: %{name: :tool_call_delta}}, event) do
          assert_receive {:stream_request, producer, request}
          assert_stream_request(request)
          assert request.json["toolConfig"]["functionCallingConfig"]["mode"] == "ANY"
          send(producer, :continue)
        end

        event
      end)

    assert [%Events.Custom{}, %Events.Message{message: message}, %Events.Done{result: response}] = events
    assert {:ok, ^message} = Messages.response_to_message(response)
    assert message.content == ""

    assert [%{id: "call-ping", name: "benchmark_ping", args: %{"value" => "ping"}, thought_signature: "sig-call-ping"}] =
             message.tool_calls

    assert message.status == "STOP"
    assert message.response_metadata.finish_message == "Model generated function call(s)."
    assert message.response_metadata.model_version == "gemini-3.8-flash"
    assert message.response_metadata.service_tier == "priority"
    assert message.response_metadata.grounding_metadata == %{"webSearchQueries" => ["ping"]}
    assert message.response_metadata.provider_content == [part]

    assert message.usage_metadata == %{
             input_tokens: 12,
             output_tokens: 8,
             total_tokens: 20,
             input_token_details: %{cache_read: 2},
             output_token_details: %{reasoning: 3}
           }

    refute_received {:stream_request, _, _}
  end

  for delivery <- [:whole, :events, :bytes] do
    @delivery delivery
    test "#{delivery} delivery preserves ordered multiple calls, reasoning, usage and replay signatures" do
      parts = [
        %{"text" => "Thinking ", "thought" => true},
        %{"text" => "about π", "thought" => true},
        call_part("call-one", "one"),
        call_part("call-two", "two"),
        %{"text" => "", "thoughtSignature" => "empty-text-signature"}
      ]

      responses =
        Enum.map(parts, &candidate([&1], false)) ++
          [
            terminal(),
            %{"usageMetadata" => %{"promptTokenCount" => 9, "cachedContentTokenCount" => 2}},
            Map.update!(usage(), "usageMetadata", &Map.delete(&1, "cachedContentTokenCount"))
          ]

      # Also exercise CRLF and the final SSE event without a terminating newline.
      wire = responses |> Enum.map_join(&sse/1) |> String.replace("\n", "\r\n") |> String.trim_trailing()

      chunks =
        case @delivery do
          :whole -> [wire]
          :events -> Enum.map(responses, &sse/1)
          :bytes -> for <<byte <- wire>>, do: <<byte>>
        end

      model = model(fn _ -> {chunks, ok_response()} end)
      assert {:ok, stream} = CoreChatModel.stream_exact_typed_events(model, ~s({"contents":[]}))
      events = Enum.map(stream, &unwrap/1)
      assert [%Events.Message{message: message}] = Enum.filter(events, &is_struct(&1, Events.Message))
      assert [%Events.Done{}] = Enum.filter(events, &is_struct(&1, Events.Done))
      refute Enum.any?(events, &is_struct(&1, Events.Error))
      assert Enum.map(message.tool_calls, & &1.id) == ["call-one", "call-two"]
      assert Enum.map(message.tool_calls, & &1.args) == [%{"value" => "one"}, %{"value" => "two"}]
      assert message.usage_metadata.total_tokens == 20
      assert message.usage_metadata.input_token_details.cache_read == 2

      assert [reasoning | replay_parts] = message.response_metadata.provider_content
      assert reasoning == %{"text" => "Thinking about π", "thought" => true}
      assert replay_parts == Enum.drop(parts, 2)

      binding = %{provider: "google", model: "gemini-3.8-flash", api: "generate_content"}
      assert {:ok, projection} = Replay.project(message, binding)
      assert {:ok, restored} = Replay.restore(projection, binding)
      assert {:ok, {nil, [encoded]}} = Messages.encode_messages([restored])
      assert encoded["parts"] == message.response_metadata.provider_content
      assert_receive {:stream_request, _, request}
      assert request.body == ~s({"contents":[]})
      refute_received {:stream_request, _, _}
    end
  end

  test "text and reasoning stay live without duplicating text at completion" do
    responses = [
      candidate([%{"text" => "Plan", "thought" => true}], false),
      candidate([%{"text" => "Hello "}], false),
      candidate([%{"text" => "world"}], false),
      terminal()
    ]

    model = model(fn _ -> {Enum.map(responses, &sse/1), ok_response()} end)
    assert {:ok, stream} = ChatModel.stream_typed_events(model, [Message.user("Hello")])
    events = Enum.map(stream, &unwrap/1)
    assert for(%Events.Token{text: text} <- events, do: text) == ["Hello ", "world"]
    assert [%Events.Message{message: message}, %Events.Done{}] = Enum.take(events, -2)
    assert Message.text(message) == "Hello world"
  end

  for provider_ids <- [true, false] do
    @provider_ids provider_ids
    test "agent executes each streamed call once and replays results with provider IDs=#{@provider_ids}" do
      parent = self()
      parts = [call_part("call-one", "one"), call_part("call-two", "two")]

      parts =
        if @provider_ids,
          do: parts,
          else: Enum.map(parts, &Map.update!(&1, "functionCall", fn call -> Map.delete(call, "id") end))

      model =
        model(fn request ->
          responses =
            if length(request.json["contents"]) == 1 do
              [candidate([hd(parts)], false), candidate([List.last(parts)], false), terminal(), usage()]
            else
              [candidate([%{"text" => "Done."}], true), usage()]
            end

          {Enum.map(responses, &sse/1), ok_response()}
        end)

      ping =
        tool(fn args, _opts ->
          send(parent, {:executed, args})
          "pong-#{args["value"]}"
        end)

      assert {:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [ping], model_opts: [stream: true])

      assert {:ok, stream} =
               BeamWeaver.Agent.stream_events(agent, %{messages: [Message.user("Ping twice")]},
                 live: true,
                 stream_mode: :events
               )

      events = Enum.map(stream, &unwrap/1)
      refute Enum.any?(events, &is_struct(&1, Events.Error))
      assert_receive {:executed, %{"value" => "one"}}
      assert_receive {:executed, %{"value" => "two"}}
      refute_received {:executed, _}
      assert_receive {:stream_request, _, first}
      assert_receive {:stream_request, _, second}
      refute_received {:stream_request, _, _}
      assert_stream_request(first)
      assert_stream_request(second)

      replayed_parts = Enum.map(parts, &Map.update!(&1, "functionCall", fn call -> Map.delete(call, "id") end))

      assert [_, %{"role" => "model", "parts" => ^replayed_parts}, %{"role" => "user", "parts" => results}] =
               second.json["contents"]

      result_ids = Enum.map(results, & &1["functionResponse"]["id"])
      assert length(Enum.uniq(result_ids)) == 2
      if @provider_ids, do: assert(result_ids == ["call-one", "call-two"])

      assert Enum.map(results, & &1["functionResponse"]["response"]) ==
               [%{"content" => "pong-one"}, %{"content" => "pong-two"}]

      messages = for %Events.Message{message: %Message{role: :assistant} = message} <- events, do: message
      assert Enum.map(messages, &Message.text/1) == ["", "Done."]
      assert Enum.map(messages, & &1.usage_metadata.total_tokens) == [20, 20]
      assert Enum.map(hd(messages).tool_calls, & &1.id) == result_ids
    end
  end

  for failure <- [
        :empty,
        :incomplete,
        :malformed,
        :truncated_trailer,
        :provider,
        :provider_after_stop,
        :http,
        :transport
      ] do
    @failure failure
    test "#{failure} failure emits an error without a completed message or Done" do
      provider_error = %{"error" => %{"code" => 503, "status" => "UNAVAILABLE", "message" => "try again"}}

      {chunks, result, error_type} =
        case @failure do
          :malformed ->
            {["data: {bad-json}\n\n", sse(terminal())], ok_response(), :invalid_provider_stream}

          :truncated_trailer ->
            {[sse(terminal()), "data: {\"usageMetadata\":"], ok_response(), :invalid_provider_stream}

          :empty ->
            {[], ok_response(), :invalid_provider_stream}

          :incomplete ->
            {[sse(candidate([call_part("call-ping", "ping")], false))], ok_response(), :invalid_provider_stream}

          :provider ->
            {[sse(provider_error)], ok_response(), :response_error}

          :provider_after_stop ->
            {[sse(terminal()), sse(provider_error)], ok_response(), :response_error}

          :http ->
            {[], {:ok, Response.new(status: 503, body: provider_error, headers: [{"x-request-id", "req-error"}])},
             :http_error}

          :transport ->
            {[sse(terminal())], {:error, BeamWeaver.Transport.Error.new(:closed, "connection closed")},
             :transport_error}
        end

      model = model(fn _ -> {chunks, result} end)
      assert {:ok, stream} = ChatModel.stream_typed_events(model, [Message.user("Ping")])
      events = Enum.map(stream, &unwrap/1)
      assert [%Events.Error{error: error}] = Enum.filter(events, &is_struct(&1, Events.Error))
      assert error.type == error_type
      if @failure in [:provider, :provider_after_stop, :http], do: assert(error.message == "try again")
      if @failure == :http, do: assert(error.details.request_id == "req-error")
      refute Enum.any?(events, &(is_struct(&1, Events.Message) or is_struct(&1, Events.Done)))
      assert_receive {:stream_request, _, _}
      refute_received {:stream_request, _, _}
    end
  end

  test "agent does not execute partial calls or complete successfully after a stream error" do
    parent = self()
    chunks = [sse(candidate([call_part("call-ping", "ping")], false))]
    model = model(fn _ -> {chunks, ok_response()} end)

    ping =
      tool(fn args, _ ->
        send(parent, {:executed, args})
        "pong"
      end)

    assert {:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [ping], model_opts: [stream: true])
    assert {:error, error} = BeamWeaver.Agent.invoke(agent, %{messages: [Message.user("Ping")]})
    assert error.type == :invalid_provider_stream
    refute_received {:executed, _}
    assert_receive {:stream_request, _, _}
    refute_received {:stream_request, _, _}
  end

  defp model(respond) do
    ChatModel.new(
      model: "gemini-3.8-flash",
      api_key: "fixture-only",
      transport: Transport,
      transport_opts: [parent: self(), respond: respond]
    )
  end

  defp tool(handler \\ fn _, _ -> "pong" end) do
    Tool.from_function!(
      name: "benchmark_ping",
      description: "Return an inert test value",
      input_schema: %{type: :object, properties: %{value: %{type: :string}}, required: ["value"]},
      handler: handler
    )
  end

  defp call_part(id, value) do
    %{
      "functionCall" => %{"id" => id, "name" => "benchmark_ping", "args" => %{"value" => value}},
      "thoughtSignature" => "sig-#{id}"
    }
  end

  defp candidate(parts, complete?) do
    candidate = %{"index" => 0, "content" => %{"role" => "model", "parts" => parts}}
    candidate = if complete?, do: Map.put(candidate, "finishReason", "STOP"), else: candidate
    %{"responseId" => "google-stream", "modelVersion" => "gemini-3.8-flash", "candidates" => [candidate]}
  end

  defp terminal do
    %{
      "candidates" => [
        %{
          "finishReason" => "STOP",
          "finishMessage" => "Model generated function call(s).",
          "groundingMetadata" => %{"webSearchQueries" => ["ping"]}
        }
      ]
    }
  end

  defp usage do
    %{
      "usageMetadata" => %{
        "promptTokenCount" => 12,
        "candidatesTokenCount" => 5,
        "thoughtsTokenCount" => 3,
        "cachedContentTokenCount" => 2,
        "totalTokenCount" => 20
      }
    }
  end

  defp ok_response, do: {:ok, Response.new(status: 200, headers: [{"x-gemini-service-tier", "priority"}])}
  defp sse(response), do: "data: #{BeamWeaver.JSON.encode!(response)}\n\n"
  defp unwrap(%Envelope{event: event}), do: event
  defp unwrap(event), do: event

  defp assert_stream_request(request) do
    assert request.method == :post
    assert String.ends_with?(request.url, "/models/gemini-3.8-flash:streamGenerateContent?alt=sse")
  end
end
