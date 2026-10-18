defmodule BeamWeaver.Provider.CredentialsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Response

  defmodule RecordingTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:transport_request, request})
      {:ok, Response.new(status: 200, headers: [], body: "{}")}
    end
  end

  @chat_models [
    {"openai:gpt-5.4-mini", [], :openai},
    {"openai:gpt-5.4-mini", [api: :chat_completions], :openai},
    {"anthropic:claude-haiku-4-5", [], :anthropic},
    {"google:gemini-3.5-flash", [], :google},
    {"xai:grok-4.6", [], :xai},
    {"xai:grok-4.6", [api: :chat_completions], :xai},
    {"moonshot:kimi-k2.6", [], :moonshot},
    {"zai:glm-5.2", [], :zai},
    {"deepseek:deepseek-v4-flash", [], :deepseek},
    {"deepseek:deepseek-v4-flash", [api: :responses], :deepseek}
  ]

  test "every chat provider fails before any request when its API key is missing" do
    for {id, opts, provider} <- @chat_models do
      model = Models.init_chat_model!(id, opts ++ [transport: RecordingTransport, transport_opts: [parent: self()]])

      assert {:error, %Error{type: :missing_api_key, details: %{provider: ^provider, retryable: false}}} =
               ChatModel.invoke(model, "Where is my order A-1001?"),
             "#{id} #{inspect(opts)} sent a request without an API key"

      assert {:error, %Error{type: :missing_api_key}} =
               ChatModel.stream_typed_events(model, "Where is my order A-1001?")

      refute_received {:transport_request, _request}
    end
  end

  test "embedding models fail before any request when the API key is missing" do
    for id <- ["openai:text-embedding-3-small", "openai:text-embedding-3-large"] do
      model = Models.init_embeddings!(id, transport: RecordingTransport, transport_opts: [parent: self()])

      assert {:error, %Error{type: :missing_api_key}} = EmbeddingModel.embed_query(model, "refunds")
      refute_received {:transport_request, _request}
    end
  end

  test "a key from a function or credentials in a header count as present" do
    client =
      HTTPClient.new(
        provider: :openai,
        endpoint: "https://api.example.test/v1/responses",
        auth_header: "authorization",
        auth_prefix: "Bearer",
        api_key: fn -> "sk-from-function" end,
        transport: RecordingTransport,
        transport_opts: [parent: self()]
      )

    assert {:ok, %Response{status: 200}} = HTTPClient.post_json(client, %{})
    assert_received {:transport_request, request}
    assert {"authorization", "Bearer sk-from-function"} in request.headers

    oauth = %{client | api_key: nil, default_headers: [{"Authorization", "Bearer oauth-token"}]}

    assert {:ok, %Response{status: 200}} = HTTPClient.post_json(oauth, %{})
    assert_received {:transport_request, _request}

    assert {:error, %Error{type: :missing_api_key}} = HTTPClient.post_json(%{client | api_key: fn -> nil end}, %{})
    refute_received {:transport_request, _request}
  end

  test "a transport error keeps its type as the reason" do
    error =
      BeamWeaver.Transport.Error.new(:cassette_mismatch, "no matching cassette interaction", %{
        cassette: "test/cassettes/openai.yml",
        request: %{method: "POST", url: "https://api.openai.com/v1/responses"}
      })

    assert %Error{type: :transport_error, details: details} =
             ResponseDecoder.transport_error(error, provider: :openai)

    assert details.reason == :cassette_mismatch
    assert details.retryable == false
    assert details.cassette == "test/cassettes/openai.yml"
    assert details.request.url == "https://api.openai.com/v1/responses"

    refused = BeamWeaver.Transport.Error.new(:transport_failure, "transport request failed", %{reason: ":econnrefused"})

    assert %Error{type: :connection, details: %{reason: :transport_failure, cause: ":econnrefused", retryable: true}} =
             ResponseDecoder.transport_error(refused, provider: :openai)

    timeout = BeamWeaver.Transport.Error.new(:timeout, "transport request timed out")

    assert %Error{type: :timeout, details: %{reason: :timeout, retryable: true}} =
             ResponseDecoder.transport_error(timeout, provider: :openai)
  end

  test "a cassette mismatch reaches the caller with its type" do
    path = Path.join(System.tmp_dir!(), "beam_weaver_credentials_#{System.unique_integer([:positive])}.yml")

    File.write!(path, """
    requests:
    - method: POST
      uri: https://api.openai.com/v1/responses
      body: '{"model": "gpt-5.4-mini", "stream": false, "input": "something else"}'
    responses:
    - status: {code: 200, message: OK}
      headers: {content-type: [application/json]}
      body:
        string: '{}'
    """)

    on_exit(fn -> File.rm(path) end)

    model =
      Models.init_chat_model!("openai:gpt-5.4-mini",
        api_key: "test-key",
        transport: BeamWeaver.Transport.Replay,
        transport_opts: [cassette_path: path]
      )

    assert {:error, %Error{type: :transport_error, details: %{reason: :cassette_mismatch} = details}} =
             ChatModel.invoke(model, "Where is my order A-1001?")

    assert [%{url: "https://api.openai.com/v1/responses"}] = details.expected
    assert details.request.json_body =~ "Where is my order A-1001?"
  end
end
