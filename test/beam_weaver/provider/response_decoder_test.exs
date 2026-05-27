defmodule BeamWeaver.Provider.ResponseDecoderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.ResponseDecoder
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
end
