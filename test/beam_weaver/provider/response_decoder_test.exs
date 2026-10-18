defmodule BeamWeaver.Provider.ResponseDecoderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Redactor
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  defmodule StreamTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(%Request{}, _opts), do: {:ok, Response.new(status: 200, body: %{})}

    @impl true
    def stream_reduce(%Request{}, opts, acc, reducer) do
      send(Keyword.fetch!(opts, :parent), {:stream_timeout, Keyword.fetch!(opts, :timeout)})

      acc =
        ["data: {\"text\":\"hel\"}\n\n", "data: {\"text\":\"lo\"}\n\n"]
        |> Enum.reduce(acc, fn chunk, acc -> reducer.(acc, chunk) end)

      {:ok, Response.new(status: 200, headers: [{"x-stream-request-id", "stream-1"}], metadata: %{source: :test}), acc}
    end
  end

  defmodule MetadataTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(%Request{}, opts) do
      send(Keyword.fetch!(opts, :parent), {:transport_opts, opts})

      {:ok,
       Response.new(
         status: 200,
         headers: [{"x-api-key", "response-secret"}],
         body: ~s({"ok":true,"api_key":"response-secret"})
       )}
    end
  end

  defmodule ErrorStreamTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(%Request{}, _opts), do: {:ok, Response.new(status: 429, body: %{})}

    @impl true
    def stream_reduce(%Request{}, _opts, acc, _reducer) do
      {:ok,
       Response.new(
         status: 429,
         headers: [{"retry-after", "2"}],
         body: ~s({"error":{"message":"slow down"}}),
         metadata: %{source: :test}
       ), acc}
    end
  end

  test "depleted credits are not treated as a retryable rate limit" do
    depleted =
      Response.new(
        status: 429,
        body: ~s({"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Your prepayment credits are depleted."}})
      )

    assert {:error, %{type: :billing_exhausted, details: %{retryable: false}}} =
             ResponseDecoder.json({:ok, depleted}, provider: :google)

    rate_limit =
      Response.new(
        status: 429,
        body: ~s({"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Too many requests. Try again later."}})
      )

    assert {:error, %{type: :rate_limit, details: %{retryable: true}}} =
             ResponseDecoder.json({:ok, rate_limit}, provider: :google)
  end

  # Every provider decodes its HTTP errors here, so a status gets the same
  # type, and `retryable`, from every provider.
  test "an HTTP error's type and retryable follow its status" do
    for {status, type, retryable} <- [
          {400, :invalid_request, false},
          {401, :authentication, false},
          {402, :billing_exhausted, false},
          {403, :permission_denied, false},
          {404, :not_found, false},
          {409, :http_error, true},
          {413, :http_error, false},
          {422, :invalid_request, false},
          {429, :rate_limit, true},
          {500, :server_error, true},
          {501, :server_error, true},
          {529, :server_error, true}
        ] do
      response = Response.new(status: status, body: ~s({"error":{"message":"The request failed."}}))

      assert %Error{type: ^type, details: %{status: ^status, retryable: ^retryable}} =
               ResponseDecoder.http_error(response, provider: :openai)
    end
  end

  # OpenAI-compatible servers word an overflow their own way, and some answer
  # it with a 413 or 422, so those statuses count when the message says so.
  test "context overflow errors of OpenAI-compatible servers" do
    for {status, message} <- [
          {400, "the request exceeds the available context size, try increasing it"},
          {400, "litellm.ContextWindowExceededError: litellm.BadRequestError: prompt too long"},
          {400, "Context limit exceeded for model"},
          {413, "prompt is too long: 250000 tokens > 200000 maximum"},
          {422, "This model's maximum context length is 4096 tokens."}
        ] do
      response = Response.new(status: status, body: BeamWeaver.JSON.encode!(%{"error" => %{"message" => message}}))

      assert %Error{type: :context_overflow, details: %{status: ^status, retryable: false}} =
               ResponseDecoder.http_error(response, provider: :openai)
    end
  end

  # Text Generation Inference answers with the message in a plain `error`
  # string and a 422.
  test "context overflow errors of Text Generation Inference" do
    for message <- [
          "Input validation error: `inputs` tokens + `max_new_tokens` must be <= 4096. Given: 5000 `inputs` tokens and 100 `max_new_tokens`",
          "Input validation error: `inputs` must have less than 4096 tokens. Given: 5000"
        ] do
      body = BeamWeaver.JSON.encode!(%{"error" => message, "error_type" => "validation"})

      assert %Error{type: :context_overflow, details: %{status: 422}} =
               ResponseDecoder.http_error(Response.new(status: 422, body: body), provider: :openai)
    end
  end

  test "json decodes successful responses and can attach response headers" do
    response =
      Response.new(
        status: 200,
        headers: [{"x-request-id", "req-1"}],
        body: ~s({"ok":true})
      )

    assert {:ok,
            %{
              "ok" => true,
              "_beamweaver_response_headers" => %{"x-request-id" => "req-1"}
            }} =
             ResponseDecoder.json({:ok, response},
               provider_name: "TestProvider",
               include_response_headers: true
             )
  end

  test "json does not decode provider headers in the shared decoder" do
    response =
      Response.new(
        status: 200,
        headers: [
          {"x-request-id", "req-openai"},
          {"x-ratelimit-remaining-tokens", "99"},
          {"content-type", "application/json"}
        ],
        body: ~s({"ok":true})
      )

    assert {:ok, %{"ok" => true} = decoded} =
             ResponseDecoder.json({:ok, response}, provider: :openai, provider_name: "OpenAI")

    refute Map.has_key?(decoded, "_beamweaver_response_headers")
    refute Map.has_key?(decoded, "_beamweaver_response_header_metadata")
  end

  test "http errors preserve context-overflow and request metadata" do
    response =
      Response.new(
        status: 400,
        headers: [{"x-request-id", "req-2"}],
        body: ~s({"error":{"message":"context length exceeded","code":"context_length_exceeded"}})
      )

    assert {:error,
            %Error{
              type: :context_overflow,
              message: "context length exceeded",
              details: %{status: 400, code: "context_length_exceeded", request_id: "req-2"}
            }} = ResponseDecoder.json({:ok, response}, provider_name: "TestProvider")
  end

  test "http client shared SSE helper streams parsed events with transport opts" do
    client =
      HTTPClient.new(
        endpoint: "https://example.test/stream",
        transport: StreamTransport,
        transport_opts: [parent: self()],
        timeout: 123
      )

    assert {:ok, stream} =
             HTTPClient.stream_sse(
               client,
               %{"stream" => true},
               [],
               fn events -> Enum.map(events, &get_in(&1, ["data", "text"])) end,
               &ResponseDecoder.json(&1, provider_name: "TestProvider")
             )

    assert Enum.to_list(stream) == ["hel", "lo"]
    assert_received {:stream_timeout, 123}
  end

  test "http client shared SSE helper carries state between parser batches" do
    client =
      HTTPClient.new(
        endpoint: "https://example.test/stream",
        transport: StreamTransport,
        transport_opts: [parent: self()],
        timeout: 123
      )

    parser = fn events, prefix ->
      text = Enum.map_join(events, &get_in(&1, ["data", "text"]))
      value = to_string(prefix || "") <> text
      {if(text == "", do: [], else: [value]), value}
    end

    assert {:ok, stream} =
             HTTPClient.stream_sse(
               client,
               %{"stream" => true},
               [],
               parser,
               &ResponseDecoder.json(&1, provider_name: "TestProvider")
             )

    assert Enum.to_list(stream) == ["hel", "hello"]
  end

  test "http client shared SSE helper invokes the opt-in response callback once and stays lazy" do
    parent = self()

    client =
      HTTPClient.new(
        endpoint: "https://example.test/stream",
        transport: StreamTransport,
        transport_opts: [parent: parent],
        timeout: 123
      )

    assert {:ok, stream} =
             HTTPClient.stream_sse(
               client,
               %{"stream" => true},
               [on_response: fn response -> send(parent, {:lazy_sse_response, response}) end],
               fn events -> Enum.map(events, &get_in(&1, ["data", "text"])) end,
               &ResponseDecoder.json(&1, provider_name: "TestProvider")
             )

    refute_received {:lazy_sse_response, _response}
    assert Enum.to_list(stream) == ["hel", "lo"]

    assert_received {:lazy_sse_response,
                     %Response{
                       status: 200,
                       headers: [{"x-stream-request-id", "stream-1"}],
                       metadata: %{source: :test}
                     }}

    refute_received {:lazy_sse_response, _response}
  end

  test "http client shared SSE helper invokes the response callback for HTTP failures" do
    parent = self()

    client =
      HTTPClient.new(
        endpoint: "https://example.test/stream",
        transport: ErrorStreamTransport
      )

    assert {:ok, stream} =
             HTTPClient.stream_sse(
               client,
               %{"stream" => true},
               [on_response: fn response -> send(parent, {:failed_sse_response, response}) end],
               fn _events -> [] end,
               &ResponseDecoder.json(&1, provider_name: "TestProvider")
             )

    assert [
             %BeamWeaver.Stream.Events.Error{
               error: %Error{type: :rate_limit, message: "slow down"}
             }
           ] = Enum.to_list(stream)

    assert_received {:failed_sse_response,
                     %Response{
                       status: 429,
                       headers: [{"retry-after", "2"}],
                       body: ~s({"error":{"message":"slow down"}})
                     }}

    refute_received {:failed_sse_response, _response}
  end

  test "http client attaches redacted metadata for Req and Finch telemetry" do
    client =
      HTTPClient.new(
        provider: :moonshot,
        endpoint: "https://api.moonshot.test/v1/chat/completions?api_key=query-secret",
        api_key: "request-secret",
        auth_header: "authorization",
        auth_prefix: "Bearer",
        transport: MetadataTransport,
        transport_opts: [parent: self()]
      )

    request_body = %{
      "model" => "kimi-k2.6",
      "api_key" => "body-secret",
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_account"}}]
    }

    assert {:ok, %Response{status: 200}} = HTTPClient.post_json(client, request_body, timeout: 321)

    assert_received {:transport_opts, opts}
    metadata = Keyword.fetch!(opts, :beam_weaver_http_metadata)

    assert metadata.provider == :moonshot
    assert metadata.method == :post
    assert metadata.timeout_ms == 321
    assert metadata.url == "https://api.moonshot.test/v1/chat/completions?api_key=#{Redactor.redacted()}"
    assert metadata.headers == [{"authorization", Redactor.redacted()}, {"content-type", "application/json"}]
    assert metadata.request_body_summary.tools_count == 1
    assert metadata.request_body_summary.tool_names == ["lookup_account"]

    metadata_text = inspect(metadata)
    refute metadata_text =~ "request-secret"
    refute metadata_text =~ "body-secret"
    refute metadata_text =~ "response-secret"
    refute metadata_text =~ "query-secret"
  end
end
