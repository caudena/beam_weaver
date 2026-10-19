defmodule BeamWeaver.Google.LongDecodeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.{ChatModel, Message}
  alias BeamWeaver.Google.Client
  alias BeamWeaver.Models
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Response

  defmodule Transport do
    @behaviour BeamWeaver.Transport

    def request(request, opts) do
      response = next(request, opts)
      {:ok, Response.new(status: 200, body: response)}
    end

    def stream_reduce(request, opts, acc, reducer) do
      {chunks, result} = next(request, opts)

      acc =
        Enum.reduce(chunks, acc, fn
          :block, acc ->
            send(opts[:parent], {:blocked, self()})

            receive do
              :continue -> acc
            after
              5_000 -> raise "stream was not cancelled"
            end

          chunk, acc ->
            reducer.(acc, "data: " <> Jason.encode!(chunk) <> "\n\n")
        end)

      case result do
        :ok -> {:ok, Response.new(status: 200, body: "", headers: [{"x-gemini-service-tier", "flex"}]), acc}
        {:http, status, body} -> {:ok, Response.new(status: status, body: body), acc}
        {:error, error} -> {:error, error, acc}
      end
    end

    defp next(request, opts) do
      send(opts[:parent], {:request, request})
      Agent.get_and_update(opts[:script], fn [reply | rest] -> {reply, rest} end)
    end
  end

  test "invoke combines thinking-only and text hops, original requests, usage and signed parts" do
    thinking = %{"text" => "Reasoning", "thought" => true, "thoughtSignature" => "signed-1"}
    tool = %{"functionCall" => %{"name" => "lookup", "args" => %{}, "id" => "call-1"}, "thoughtSignature" => "signed-2"}
    first = reply([thinking], "CONTINUATION", "hop-1", usage(100, 0, 10, 50))
    last = reply([%{"text" => "Answer"}, tool], "STOP", nil, usage(110, 5, 0, 90))
    {model, script} = model([{[first], :ok}, {[last], :ok}], max_output_tokens: 262_144)
    messages = [Message.system("policy"), Message.user("question")]

    assert {:ok, result} = ChatModel.invoke(model, messages)
    assert Message.text(result) == "Answer"
    assert result.status == "STOP"
    assert [%{name: "lookup", thought_signature: "signed-2"}] = result.tool_calls
    assert thinking in result.response_metadata.provider_content
    assert result.usage_metadata.input_tokens == 210
    assert result.usage_metadata.initial_input_tokens == 100
    assert result.usage_metadata.output_tokens == 15
    assert result.usage_metadata.total_tokens == 225
    assert result.usage_metadata.context_tokens == 115
    assert result.usage_metadata.input_token_details.cache_read == 140
    assert result.response_metadata.usage.initial_input_tokens == 100
    assert result.response_metadata.usage.context_tokens == 115

    assert result.usage_metadata.input_token_details.prompt_tokens_details == [
             %{"modality" => "TEXT", "tokenCount" => 210}
           ]

    assert_received {:request, request1}
    assert_received {:request, request2}
    assert request1.url =~ ":streamGenerateContent"
    assert request2.json == Map.put(request1.json, "continuationToken", "hop-1")
    assert request1.json["generationConfig"]["maxOutputTokens"] == 262_144
    assert request1.json["systemInstruction"] == %{"parts" => [%{"text" => "policy"}]}
    assert Agent.get(script, & &1) == []
  end

  test "streaming emits one terminal message and Done across hops, preserving split JSON" do
    first = reply([%{"text" => "{\"answer\":"}], "CONTINUATION", "one", usage(10, 3))
    last = reply([%{"text" => "42}"}], "STOP", nil, usage(13, 2))
    {model, _} = model([{[first], :ok}, {[last], :ok}])
    assert {:ok, stream} = ChatModel.stream_typed_events(model, "question")
    events = Enum.map(stream, & &1.event)
    assert for(%Events.Token{text: text} <- events, do: text) == ["{\"answer\":", "42}"]
    assert [%Events.Message{message: message}] = Enum.filter(events, &match?(%Events.Message{}, &1))
    assert Jason.decode!(Message.text(message)) == %{"answer" => 42}
    assert [%Events.Done{usage: %{"promptTokenCount" => 23}}] = Enum.filter(events, &match?(%Events.Done{}, &1))
    refute Enum.any?(events, &match?(%Events.Error{}, &1))
  end

  test "text streams and collected responses use the same continuation behavior" do
    for mode <- [:text, :collected] do
      first = reply([%{"text" => "A"}], "CONTINUATION", "one", usage(10, 1))
      last = reply([%{"text" => "B"}], "STOP", nil, usage(11, 1))
      {model, _} = model([{[first], :ok}, {[last], :ok}])

      case mode do
        :text ->
          assert {:ok, stream} = ChatModel.stream(model, "question")
          assert Enum.to_list(stream) == ["A", "B"]

        :collected ->
          assert {:ok, message} = BeamWeaver.Google.ChatModel.stream_response(model, [Message.user("question")])
          assert Message.text(message) == "AB"
          assert message.usage_metadata.total_tokens == 23
      end
    end
  end

  test "a dropped stream resumes the latest checkpoint and discards speculative output and usage" do
    c1 = reply([%{"text" => "A"}], nil, "one", usage(100, 1))
    c2 = reply([%{"text" => "B"}], nil, "two", usage(100, 2))
    discarded = reply([%{"text" => "discard"}], nil, nil, usage(100, 999))
    last = reply([%{"text" => "C"}], "STOP", nil, usage(102, 1))
    {model, _} = model([{[c1, c2, discarded], closed()}, {[last], :ok}])
    assert {:ok, stream} = ChatModel.stream_typed_events(model, "question")
    events = Enum.map(stream, & &1.event)
    assert for(%Events.Token{text: text} <- events, do: text) == ["A", "B", "C"]
    assert [%Events.Message{message: message}] = Enum.filter(events, &match?(%Events.Message{}, &1))
    assert Message.text(message) == "ABC"
    assert message.usage_metadata.input_tokens == 202
    assert message.usage_metadata.output_tokens == 3
    assert_received {:request, r1}
    assert_received {:request, r2}
    assert r2.json == Map.put(r1.json, "continuationToken", "two")
  end

  test "disconnect before a checkpoint restarts the original request without duplicate output" do
    partial = reply([%{"text" => "discard"}], nil, nil, usage(100, 99))
    last = reply([%{"text" => "done"}], "STOP", nil, usage(100, 1))

    for failure <- [closed(), :ok] do
      {model, _} = model([{[partial], failure}, {[last], :ok}])
      assert {:ok, stream} = ChatModel.stream_typed_events(model, "question")
      events = Enum.map(stream, & &1.event)
      assert for(%Events.Token{text: text} <- events, do: text) == ["done"]
      assert [%Events.Done{usage: %{"totalTokenCount" => 101}}] = Enum.filter(events, &match?(%Events.Done{}, &1))
      assert_received {:request, r1}
      assert_received {:request, r2}
      assert r1.json == r2.json
    end
  end

  test "MAX_TOKENS never increases the user's cap or requests another hop" do
    last = reply([%{"text" => "partial"}], "MAX_TOKENS", "resume-manually", usage(100, 10))
    {model, script} = model([{[last], :ok}], max_output_tokens: 10)
    assert {:ok, result} = ChatModel.invoke(model, "question")
    assert result.response_metadata.outcome.turn_disposition == :output_limit
    assert result.response_metadata.continuation_token == "resume-manually"
    assert_received {:request, request}
    assert request.json["generationConfig"]["maxOutputTokens"] == 10
    assert Agent.get(script, & &1) == []
    refute_received {:request, _}
  end

  test "manual opt out is available on the model and per call" do
    response = reply([%{"text" => "partial"}], "CONTINUATION", "one", usage(100, 10))

    for opts <- [[automatic_continuation: false], []] do
      {model, _} = model([response], opts)
      call_opts = if opts == [], do: [automatic_continuation: false], else: []
      assert {:ok, message} = ChatModel.invoke(model, "question", call_opts)
      assert message.status == "CONTINUATION"
      assert_received {:request, request}
      assert request.url =~ ":generateContent"
      assert request.json["generationConfig"]["maxOutputTokens"] == 32_768
      refute Map.has_key?(request.json, "automatic_continuation")
    end
  end

  test "missing and repeated continuation tokens fail without an infinite loop" do
    for token <- [nil, "one"] do
      first = reply([], "CONTINUATION", "one", usage(100, 0, 10))
      bad = reply([], "CONTINUATION", token, usage(110, 0, 10))
      {model, _} = model([{[first], :ok}, {[bad], :ok}])

      assert {:error, %{type: :invalid_provider_response, details: %{retryable: false}}} =
               ChatModel.invoke(model, "question")

      assert_received {:request, _}
      assert_received {:request, _}
      refute_received {:request, _}
    end
  end

  test "permanent failures do not retry and connection retries are bounded" do
    {model, _} = model([{[], {:http, 401, %{"error" => %{"message" => "bad key"}}}}])
    assert {:error, %{type: :authentication}} = ChatModel.invoke(model, "question")
    assert_received {:request, _}
    refute_received {:request, _}

    {model, _} = model([{[], closed()}, {[], closed()}], max_continuation_retries: 1)
    assert {:error, %{type: :connection}} = ChatModel.invoke(model, "question")
    assert_received {:request, _}
    assert_received {:request, _}
    refute_received {:request, _}
  end

  test "consumer cancellation stops the active HTTP hop and prevents continuation" do
    checkpoint = reply([%{"text" => "A"}], nil, "one", usage(100, 1))
    {model, _} = model([{[checkpoint, :block], :ok}])
    assert {:ok, stream} = ChatModel.stream(model, "question")
    assert Enum.take(stream, 1) == ["A"]
    assert_receive {:blocked, producer}
    ref = Process.monitor(producer)
    assert_receive {:DOWN, ^ref, :process, ^producer, _}
    assert_received {:request, _}
    refute_received {:request, _}
  end

  test "exact typed requests keep initial bytes and change only the continuation token later" do
    first = reply([], "CONTINUATION", "one", usage(100, 0, 10))
    last = reply([%{"text" => "done"}], "STOP", nil, usage(110, 1))
    {model, _} = model([{[first], :ok}, {[last], :ok}])

    body =
      "{ \"contents\": [{\"parts\":[{\"text\":\"question\"}]}], \"generationConfig\": {\"maxOutputTokens\": 123456} }"

    assert {:ok, stream} = BeamWeaver.Google.ChatModel.stream_exact_typed_events(model, body)
    assert Enum.any?(stream, &match?(%Envelope{event: %Events.Done{}}, &1))
    assert_received {:request, r1}
    assert_received {:request, r2}
    assert r1.body == body
    assert r2.json == Map.put(Jason.decode!(body), "continuationToken", "one")
  end

  test "native client also continues automatically and rejects invalid retry configuration" do
    first = reply([], "CONTINUATION", "one", usage(10, 0, 1))
    last = reply([%{"text" => "done"}], "STOP", nil, usage(11, 1))
    {model, _} = model([{[first], :ok}, {[last], :ok}])
    client = Client.new(api_key: "test", transport: Transport, transport_opts: model.transport_opts)
    assert {:ok, response} = Client.generate_content(client, model.model, %{"contents" => []})
    assert response["usageMetadata"]["promptTokenCount"] == 21

    assert {:error, %{type: :invalid_model_option}} =
             Client.stream_events(client, model.model, %{}, max_continuation_retries: -1)
  end

  test "usage-only trailers are counted once per hop and headers survive combination" do
    first = reply([%{"text" => "A"}], "CONTINUATION", "one", usage(10, 1))
    last = reply([%{"text" => "B"}], "STOP", nil, usage(11, 1))
    trailer = %{"usageMetadata" => usage(11, 2)}
    {model, _} = model([{[first], :ok}, {[last, trailer], :ok}])
    assert {:ok, result} = ChatModel.invoke(model, "question", include_response_headers: true)
    assert result.usage_metadata.input_tokens == 21
    assert result.usage_metadata.output_tokens == 3
    assert result.usage_metadata.total_tokens == 24
    assert result.response_metadata.headers.x_gemini_service_tier == "flex"
  end

  test "initial prompt size comes from the first hop's committed usage, not a provisional chunk" do
    provisional = reply([%{"text" => "ARGON_OK"}], nil, nil, usage(11, 4))
    terminal = reply([], "STOP", nil, usage(42, 8))
    {model, _} = model([{[provisional, terminal], :ok}])
    assert {:ok, result} = ChatModel.invoke(model, "question")
    assert result.usage_metadata.input_tokens == 42
    assert result.usage_metadata.initial_input_tokens == 42
    assert result.usage_metadata.context_tokens == 50
  end

  test "a transient provider error resumes after a completed hop without replaying it" do
    first = reply([%{"text" => "A"}], "CONTINUATION", "one", usage(10, 1))
    last = reply([%{"text" => "B"}], "STOP", nil, usage(11, 1))
    busy = {[], {:http, 503, %{"error" => %{"message" => "unavailable", "status" => "UNAVAILABLE"}}}}
    {model, _} = model([{[first], :ok}, busy, {[last], :ok}])
    assert {:ok, result} = ChatModel.invoke(model, "question")
    assert Message.text(result) == "AB"
    assert result.usage_metadata.total_tokens == 23
    assert_received {:request, r1}
    assert_received {:request, r2}
    assert_received {:request, r3}
    assert r2.json == r3.json
    assert r2.json == Map.put(r1.json, "continuationToken", "one")
  end

  test "the validation event bound applies across the logical call, not anew for each hop" do
    replies = for n <- 1..3, do: {[reply([], "CONTINUATION", "hop-#{n}", usage(10, 0, 1))], :ok}
    {model, _} = model(replies)
    assert {:error, %{type: :invalid_provider_stream}} = ChatModel.invoke(model, "question", max_stream_events: 2)
    assert_received {:request, _}
    assert_received {:request, _}
    assert_received {:request, _}
    refute_received {:request, _}
  end

  test "structured output is parsed once after all hops, with the same schema on every request" do
    first = reply([%{"text" => "{\"answer\":"}], "CONTINUATION", "one", usage(10, 3))
    last = reply([%{"text" => "42}"}], "STOP", nil, usage(13, 2))
    {model, _} = model([{[first], :ok}, {[last], :ok}])
    schema = %{type: :object, properties: %{answer: %{type: :integer}}, required: ["answer"]}
    assert {:ok, message} = ChatModel.invoke(model, "question", response_format: schema)
    assert message.metadata.parsed == %{"answer" => 42}
    assert_received {:request, r1}
    assert_received {:request, r2}
    assert r1.json["generationConfig"]["responseJsonSchema"] == r2.json["generationConfig"]["responseJsonSchema"]
  end

  test "a permanent error after a checkpoint emits one failure and no terminal success" do
    checkpoint = reply([%{"text" => "A"}], nil, "one", usage(10, 1))
    error = %{"error" => %{"message" => "denied", "status" => "PERMISSION_DENIED", "code" => 403}}
    {model, _} = model([{[checkpoint, error], :ok}])
    assert {:ok, stream} = ChatModel.stream_typed_events(model, "question")
    events = Enum.map(stream, & &1.event)
    assert for(%Events.Token{text: text} <- events, do: text) == ["A"]
    assert [%Events.Error{error: %{type: :permission_denied}}] = Enum.filter(events, &match?(%Events.Error{}, &1))
    refute Enum.any?(events, &match?(%Events.Done{}, &1))
    refute Enum.any?(events, &match?(%Events.Message{}, &1))
    assert_received {:request, _}
    refute_received {:request, _}
  end

  test "real HTTP long-decode streams can exceed 5 MB while explicit byte limits are honored" do
    # Checkpoint state makes the wire response much larger than visible text.
    # SSE comments exercise that transport bound without a huge output fixture.
    padding = String.duplicate(": " <> String.duplicate("x", 1_000) <> "\n\n", 5_100)
    body = padding <> "data: " <> Jason.encode!(reply([%{"text" => "done"}], "STOP", nil, usage(10, 1))) <> "\n\n"

    for {client_opts, call_opts, expected} <- [
          {[], [], :ok},
          {[], [max_response_bytes: 1_024], :limited},
          {[transport_opts: [max_response_bytes: 1_024]], [], :limited}
        ] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_host, port}} = :inet.sockname(listener)

      server =
        spawn(fn ->
          case :gen_tcp.accept(listener) do
            {:ok, socket} ->
              :gen_tcp.recv(socket, 0, 5_000)

              :gen_tcp.send(socket, [
                "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: ",
                Integer.to_string(byte_size(body)),
                "\r\nconnection: close\r\n\r\n",
                body
              ])

              :gen_tcp.close(socket)

            _ ->
              :ok
          end

          :gen_tcp.close(listener)
        end)

      on_exit(fn ->
        :gen_tcp.close(listener)
        if Process.alive?(server), do: Process.exit(server, :kill)
      end)

      client = Client.new([base_url: "http://127.0.0.1:#{port}", api_key: "test", timeout: 10_000] ++ client_opts)
      result = Client.generate_content(client, "gemini-4-argon", %{"contents" => []}, call_opts)

      case expected do
        :ok -> assert {:ok, %{"candidates" => [%{"finishReason" => "STOP"}]}} = result
        :limited -> assert {:error, %{details: %{reason: :response_too_large, retryable: false}}} = result
      end
    end
  end

  defp model(script, opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> script end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    model =
      Models.init_chat_model!(
        "google:gemini-4-argon",
        [api_key: "test", transport: Transport, transport_opts: [parent: self(), script: agent]] ++ opts
      )

    {model, agent}
  end

  defp reply(parts, reason, token, usage) do
    candidate = %{"content" => %{"role" => "model", "parts" => parts}}
    candidate = if reason, do: Map.put(candidate, "finishReason", reason), else: candidate
    candidate = if token, do: Map.put(candidate, "continuationToken", token), else: candidate
    %{"candidates" => [candidate], "usageMetadata" => usage}
  end

  defp usage(input, output, thinking \\ 0, cached \\ 0),
    do: %{
      "promptTokenCount" => input,
      "candidatesTokenCount" => output,
      "thoughtsTokenCount" => thinking,
      "cachedContentTokenCount" => cached,
      "totalTokenCount" => input + output + thinking,
      "promptTokensDetails" => [%{"modality" => "TEXT", "tokenCount" => input}]
    }

  defp closed, do: {:error, BeamWeaver.Transport.Error.new(:closed, "connection closed")}
end
