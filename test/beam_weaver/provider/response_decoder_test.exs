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

      {:ok, Response.new(status: 200), acc}
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
