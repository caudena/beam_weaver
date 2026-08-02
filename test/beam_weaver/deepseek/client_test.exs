defmodule BeamWeaver.DeepSeek.ClientTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.DeepSeek.Client
  alias BeamWeaver.DeepSeek.Error
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  defmodule CaptureTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(%Request{} = request, opts) do
      notify(opts, {:request, request, opts})
      {:ok, response(opts)}
    end

    @impl true
    def stream_reduce(%Request{} = request, opts, acc, reducer) do
      notify(opts, {:stream_request, request, opts})
      response = response(opts)

      if response.status in 200..299 do
        chunks = Keyword.get(opts, :chunks, [response.body])
        acc = Enum.reduce(chunks, acc, fn chunk, current -> reducer.(current, chunk) end)
        {:ok, %{response | body: ""}, acc}
      else
        {:ok, response, acc}
      end
    end

    defp response(opts) do
      %Response{
        status: Keyword.get(opts, :status, 200),
        headers: Keyword.get(opts, :response_headers, []),
        body: Keyword.get(opts, :response_body, ~s({"ok":true})),
        metadata: %{}
      }
    end

    defp notify(opts, message) do
      if parent = Keyword.get(opts, :parent), do: send(parent, message)
    end
  end

  test "derives every endpoint without duplicating API namespace suffixes" do
    v1_client = Client.new(base_url: "https://deepseek.test/v1/")

    assert v1_client.base_url == "https://deepseek.test/v1"
    assert v1_client.chat_completions_endpoint == "https://deepseek.test/v1/chat/completions"
    assert v1_client.responses_endpoint == "https://deepseek.test/v1/responses"
    assert v1_client.models_endpoint == "https://deepseek.test/v1/models"
    assert v1_client.balance_endpoint == "https://deepseek.test/v1/user/balance"
    assert v1_client.beta_base_url == "https://deepseek.test/beta"
    assert v1_client.beta_chat_completions_endpoint == "https://deepseek.test/beta/chat/completions"
    assert v1_client.completions_endpoint == "https://deepseek.test/beta/completions"
    assert v1_client.anthropic_base_url == "https://deepseek.test/anthropic"

    assert v1_client.anthropic_messages_endpoint ==
             "https://deepseek.test/anthropic/v1/messages"

    for suffix <- ["beta", "anthropic"] do
      client = Client.new(base_url: "https://deepseek.test/#{suffix}/")

      assert client.base_url == "https://deepseek.test"
      assert client.chat_completions_endpoint == "https://deepseek.test/chat/completions"
      assert client.responses_endpoint == "https://deepseek.test/responses"
      assert client.models_endpoint == "https://deepseek.test/models"
      assert client.balance_endpoint == "https://deepseek.test/user/balance"
      assert client.beta_base_url == "https://deepseek.test/beta"
      assert client.completions_endpoint == "https://deepseek.test/beta/completions"
      assert client.anthropic_base_url == "https://deepseek.test/anthropic"

      assert client.anthropic_messages_endpoint ==
               "https://deepseek.test/anthropic/v1/messages"
    end

    assert Client.endpoint("https://deepseek.test/beta/", "/completions") ==
             "https://deepseek.test/beta/completions"
  end

  test "a configured chat endpoint remains authoritative for beta-capable bodies" do
    client = Client.new(endpoint: "https://gateway.test/deepseek/chat")

    assert client.chat_completions_endpoint == "https://gateway.test/deepseek/chat"
    assert client.beta_chat_completions_endpoint == "https://gateway.test/deepseek/chat"
  end

  test "stable chat uses bearer auth, a 15 second default timeout, and response headers" do
    client =
      test_client(
        response_headers: [
          {"X-DS-Trace-ID", "trace-chat"},
          {"Content-Type", "application/json"},
          {"Set-Cookie", "first=1"},
          {"Set-Cookie", "second=2"}
        ],
        response_body: ~s({"id":"chat-1","choices":[]})
      )

    body = %{"model" => "deepseek-v4-flash", "messages" => []}

    assert {:ok, response} = Client.chat_completions(client, body, include_response_headers: true)
    assert response["id"] == "chat-1"

    assert response["_beamweaver_response_header_metadata"] == %{
             headers: %{x_ds_trace_id: "trace-chat"},
             request_id: "trace-chat"
           }

    assert response["_beamweaver_response_headers"] == %{
             "Content-Type" => "application/json",
             "Set-Cookie" => "second=2",
             "X-DS-Trace-ID" => "trace-chat"
           }

    assert response["_beamweaver_response_header_list"] == [
             ["X-DS-Trace-ID", "trace-chat"],
             ["Content-Type", "application/json"],
             ["Set-Cookie", "first=1"],
             ["Set-Cookie", "second=2"]
           ]

    assert_received {:request, request, transport_opts}
    assert request.method == :post
    assert request.url == "https://deepseek.test/chat/completions"
    assert request.json == body
    assert request.options[:timeout] == 15_000
    assert transport_opts[:timeout] == 15_000
    assert {"authorization", "Bearer ds-secret"} in request.headers
    assert {"user-agent", "beam_weaver-deepseek/0.1"} in request.headers
  end

  test "prefix and strict tools automatically use beta chat while explicit endpoints win" do
    client = test_client(response_body: ~s({"choices":[]}))

    prefix_body = %{
      "model" => "deepseek-v4-flash",
      "messages" => [%{"role" => "assistant", "prefix" => true, "content" => "begin"}]
    }

    assert {:ok, _response} = Client.chat_completions(client, prefix_body)
    assert_received {:request, %{url: "https://deepseek.test/beta/chat/completions"}, _opts}

    strict_body = %{
      model: "deepseek-v4-flash",
      tools: [%{type: "function", function: %{name: "lookup", strict: true}}]
    }

    assert {:ok, _response} = Client.chat_completions(client, strict_body)
    assert_received {:request, %{url: "https://deepseek.test/beta/chat/completions"}, _opts}

    assert {:ok, _response} =
             Client.chat_completions(client, prefix_body, endpoint: "https://gateway.test/explicit-chat")

    assert_received {:request, %{url: "https://gateway.test/explicit-chat"}, _opts}
  end

  test "responses, FIM, models, balance, and Anthropic messages use their exact routes" do
    client = test_client(response_body: ~s({"ok":true}))

    assert {:ok, %{"ok" => true}} = Client.responses(client, %{"model" => "deepseek-v4-flash"})
    assert_received {:request, %{method: :post, url: "https://deepseek.test/responses"}, _opts}

    assert {:ok, %{"ok" => true}} = Client.completions(client, %{"prompt" => "def fib"})
    assert_received {:request, %{method: :post, url: "https://deepseek.test/beta/completions"}, _opts}

    assert {:ok, %{"ok" => true}} = Client.models(client)
    assert_received {:request, %{method: :get, url: "https://deepseek.test/models", json: nil}, _opts}

    assert {:ok, %{"ok" => true}} = Client.balance(client)

    assert_received {:request, %{method: :get, url: "https://deepseek.test/user/balance", json: nil}, _opts}

    assert {:ok, %{"ok" => true}} =
             Client.anthropic_messages(client, %{
               "model" => "claude-sonnet-4-5",
               "messages" => [],
               "max_tokens" => 16
             })

    assert_received {:request,
                     %{
                       method: :post,
                       url: "https://deepseek.test/anthropic/v1/messages",
                       headers: headers
                     }, _opts}

    assert {"x-api-key", "ds-secret"} in headers
    assert {"anthropic-version", "2023-06-01"} in headers
    refute Enum.any?(headers, fn {name, _value} -> name == "authorization" end)
  end

  test "explicit per-surface endpoints and timeout are honored" do
    client =
      Client.new(
        api_key: "ds-secret",
        endpoint: "https://gateway.test/chat",
        responses_endpoint: "https://gateway.test/responses",
        completions_endpoint: "https://gateway.test/fim",
        models_endpoint: "https://gateway.test/models",
        balance_endpoint: "https://gateway.test/balance",
        anthropic_messages_endpoint: "https://gateway.test/messages",
        timeout: 42_000,
        transport: CaptureTransport,
        transport_opts: [parent: self(), response_body: ~s({"ok":true})]
      )

    requests = [
      {fn -> Client.chat_completions(client, %{}) end, :post, "https://gateway.test/chat"},
      {fn -> Client.responses(client, %{}) end, :post, "https://gateway.test/responses"},
      {fn -> Client.completions(client, %{}) end, :post, "https://gateway.test/fim"},
      {fn -> Client.models(client) end, :get, "https://gateway.test/models"},
      {fn -> Client.balance(client) end, :get, "https://gateway.test/balance"},
      {fn -> Client.anthropic_messages(client, %{}) end, :post, "https://gateway.test/messages"}
    ]

    for {request, method, url} <- requests do
      assert {:ok, %{"ok" => true}} = request.()

      assert_received {:request, %Request{method: ^method, url: ^url, options: request_options}, transport_opts}

      assert request_options[:timeout] == 42_000
      assert transport_opts[:timeout] == 42_000
    end
  end

  test "chat streaming is lazy and collected responses retain reasoning, usage, and headers" do
    sse = """
    data: {"id":"chat-stream","model":"deepseek-v4-pro","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"think "},"finish_reason":null}]}

    data: {"id":"chat-stream","model":"deepseek-v4-pro","choices":[{"index":0,"delta":{"reasoning_content":"more"},"finish_reason":null}]}

    data: {"id":"chat-stream","model":"deepseek-v4-pro","choices":[{"index":0,"delta":{"content":"answer"},"finish_reason":null}]}

    data: {"id":"chat-stream","model":"deepseek-v4-pro","choices":[{"index":1,"delta":{"role":"assistant","reasoning_content":"other "},"finish_reason":null}]}

    data: {"id":"chat-stream","model":"deepseek-v4-pro","choices":[{"index":1,"delta":{"reasoning_content":"thought","content":"second"},"finish_reason":null}]}

    data: {"id":"chat-stream","model":"deepseek-v4-pro","choices":[{"index":0,"delta":{},"finish_reason":"insufficient_system_resource"},{"index":1,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}

    data: [DONE]

    """

    client =
      test_client(
        response_headers: [{"x-ds-trace-id", "trace-stream"}],
        response_body: sse,
        chunks: chunk_every(sse, 17)
      )

    body = %{"model" => "deepseek-v4-pro", "messages" => [], "stream" => true}
    assert {:ok, stream} = Client.chat_completions_stream(client, body)
    refute_received {:stream_request, _request, _opts}
    assert Enum.to_list(stream) == ["answer", "second"]
    assert_received {:stream_request, %{url: "https://deepseek.test/chat/completions"}, _opts}

    assert {:ok, typed_stream} = Client.chat_completions_stream_typed_events(client, body)
    typed_events = Enum.to_list(typed_stream)

    assert Enum.any?(typed_events, fn envelope ->
             envelope.metadata == %{provider: :deepseek, block_type: :reasoning}
           end)

    assert {:ok, response} =
             Client.chat_completions_stream_response(client, body, include_response_headers: true)

    assert get_in(response, ["choices", Access.at(0), "message", "content"]) == "answer"

    assert get_in(response, ["choices", Access.at(0), "message", "reasoning_content"]) ==
             "think more"

    assert get_in(response, ["choices", Access.at(1), "message", "content"]) == "second"

    assert get_in(response, ["choices", Access.at(1), "message", "reasoning_content"]) ==
             "other thought"

    assert get_in(response, ["choices", Access.at(1), "finish_reason"]) == "stop"

    assert get_in(response, ["choices", Access.at(0), "finish_reason"]) ==
             "insufficient_system_resource"

    assert response["usage"] == %{
             "prompt_tokens" => 3,
             "completion_tokens" => 2,
             "total_tokens" => 5
           }

    assert response["_beamweaver_response_header_metadata"].request_id == "trace-stream"
    assert response["_beamweaver_response_headers"] == %{"x-ds-trace-id" => "trace-stream"}
    assert response["_beamweaver_response_header_list"] == [["x-ds-trace-id", "trace-stream"]]
  end

  test "Responses, FIM, and Anthropic collected streams reuse their wire reconstructors" do
    responses_sse = """
    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","item_id":"msg-1","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","item_id":"msg-1","output_index":0,"content_index":0,"delta":"hello"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp-1","status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}

    """

    client = test_client(response_body: responses_sse)
    body = %{"model" => "deepseek-v4-flash", "input" => "hello", "stream" => true}

    assert {:ok, stream} = Client.responses_stream(client, body)
    assert Enum.to_list(stream) == ["hello"]
    assert {:ok, response} = Client.responses_stream_response(client, body)
    assert response["id"] == "resp-1"
    assert get_in(response, ["output", Access.at(0), "content", Access.at(0), "text"]) == "hello"

    fim_sse = """
    data: {"id":"cmpl-1","object":"text_completion","model":"deepseek-v4-flash","choices":[{"index":0,"text":"foo","finish_reason":null,"logprobs":{"tokens":["foo"],"token_logprobs":[-0.1],"top_logprobs":[{"foo":-0.1}],"text_offset":[0]}}]}

    data: {"id":"cmpl-1","object":"text_completion","model":"deepseek-v4-flash","choices":[{"index":0,"text":"bar","finish_reason":"stop","logprobs":{"tokens":["bar"],"token_logprobs":[-0.2],"top_logprobs":[{"bar":-0.2}],"text_offset":[3]}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}

    data: [DONE]

    """

    client = test_client(response_body: fim_sse, chunks: chunk_every(fim_sse, 11))
    assert {:ok, stream} = Client.completions_stream(client, %{"prompt" => "f", "stream" => true})
    assert Enum.to_list(stream) == ["foo", "bar"]

    assert {:ok, fim_response} =
             Client.completions_stream_response(client, %{"prompt" => "f", "stream" => true})

    assert get_in(fim_response, ["choices", Access.at(0), "text"]) == "foobar"
    assert get_in(fim_response, ["choices", Access.at(0), "finish_reason"]) == "stop"

    assert get_in(fim_response, ["choices", Access.at(0), "logprobs"]) == %{
             "tokens" => ["foo", "bar"],
             "token_logprobs" => [-0.1, -0.2],
             "top_logprobs" => [%{"foo" => -0.1}, %{"bar" => -0.2}],
             "text_offset" => [0, 3]
           }

    assert fim_response["usage"]["total_tokens"] == 3

    anthropic_sse = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","model":"deepseek-v4-flash","content":[],"usage":{"input_tokens":2,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

    """

    client = test_client(response_body: anthropic_sse)
    anthropic_body = %{"model" => "claude-sonnet-4-5", "messages" => [], "stream" => true}
    assert {:ok, stream} = Client.anthropic_messages_stream(client, anthropic_body)
    assert Enum.to_list(stream) == ["hi"]

    assert {:ok, anthropic_response} =
             Client.anthropic_messages_stream_response(client, anthropic_body)

    assert anthropic_response["id"] == "msg-1"
    assert get_in(anthropic_response, ["content", Access.at(0), "text"]) == "hi"
    assert anthropic_response["stop_reason"] == "end_turn"
  end

  test "normalizes DeepSeek error status, JSON octet-stream bodies, trace IDs, and retryability" do
    cases = [
      {401, "authentication_error", :authentication_error, false},
      {402, "insufficient balance", :quota_error, false},
      {429, "rate limit reached", :rate_limit_error, true},
      {503, "server overloaded", :overloaded_error, true},
      {422, "invalid parameters", :invalid_request_error, false},
      {500, "internal server error", :server_error, true}
    ]

    for {status, message, type, retryable} <- cases do
      client =
        test_client(
          status: status,
          response_headers: [
            {"Content-Type", "application/octet-stream"},
            {"X-DS-Trace-ID", "trace-#{status}"}
          ],
          response_body:
            BeamWeaver.JSON.encode!(%{
              "error" => %{"message" => message, "type" => "invalid_request_error"}
            })
        )

      assert {:error, %Error{} = error} = Client.chat_completions(client, %{})
      assert error.type == type
      assert error.message == message
      assert error.details.status == status
      assert error.details.request_id == "trace-#{status}"
      assert error.details.retryable == retryable
    end

    context_client =
      test_client(
        status: 400,
        response_body:
          ~s({"error":{"message":"Input tokens exceed the maximum context length","code":"context_length_exceeded"}})
      )

    assert {:error, %Error{type: :context_overflow}} =
             Client.chat_completions(context_client, %{})
  end

  test "stream failures use the same DeepSeek error normalization" do
    client =
      test_client(
        status: 429,
        response_body: ~s({"error":{"message":"slow down","type":"rate_limit_error"}})
      )

    assert {:ok, stream} = Client.responses_stream(client, %{"stream" => true})

    assert [%BeamWeaver.Stream.Events.Error{error: %Error{type: :rate_limit_error}}] =
             Enum.to_list(stream)
  end

  test "client Inspect redacts eager and lazy API keys without resolving lazy secrets" do
    parent = self()

    eager = Client.new(api_key: "ds-eager-secret")

    lazy =
      Client.new(
        api_key: fn ->
          send(parent, :secret_resolved)
          "ds-lazy-secret"
        end
      )

    for client <- [eager, lazy] do
      inspected = inspect(client, limit: :infinity)
      refute inspected =~ "ds-eager-secret"
      refute inspected =~ "ds-lazy-secret"
      assert inspected =~ BeamWeaver.Transport.Redactor.redacted()
    end

    refute_received :secret_resolved
  end

  defp test_client(response_opts) do
    Client.new(
      base_url: "https://deepseek.test",
      api_key: "ds-secret",
      transport: CaptureTransport,
      transport_opts: [parent: self()] ++ response_opts
    )
  end

  defp chunk_every(body, size), do: do_chunk_every(body, size, [])
  defp do_chunk_every("", _size, acc), do: Enum.reverse(acc)

  defp do_chunk_every(body, size, acc) do
    case body do
      <<chunk::binary-size(^size), rest::binary>> -> do_chunk_every(rest, size, [chunk | acc])
      chunk -> Enum.reverse([chunk | acc])
    end
  end
end
