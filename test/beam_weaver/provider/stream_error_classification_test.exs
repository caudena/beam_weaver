defmodule BeamWeaver.Provider.StreamErrorClassificationTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.ModelRetry
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.RetryPredicates
  alias BeamWeaver.Transport.Response

  # A streamed request gets a 200 event stream that breaks off with the
  # provider's error; any other request gets the same error as an HTTP error
  # response, with the status the provider documents for it.
  defmodule Scripted do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), :request)

      if request.json["stream"] == true or String.contains?(to_string(request.url), "streamGenerateContent") do
        {:ok, Response.new(status: 200, headers: sse_headers(), body: Keyword.fetch!(opts, :stream_body))}
      else
        {:ok,
         Response.new(
           status: Keyword.fetch!(opts, :status),
           headers: [{"content-type", "application/json"}],
           body: Keyword.fetch!(opts, :http_body)
         )}
      end
    end

    defp sse_headers, do: [{"content-type", "text/event-stream"}]
  end

  @openai [
    {"a rate limit", %{"code" => "rate_limit_exceeded", "type" => "requests", "message" => "Rate limit reached"}, 429,
     :rate_limit, true},
    {"an exhausted quota",
     %{"code" => "insufficient_quota", "type" => "insufficient_quota", "message" => "You exceeded your current quota"},
     429, :billing_exhausted, false},
    {"a spend limit", %{"code" => "organization_spend_limit_exceeded", "message" => "Spend limit reached"}, 429,
     :billing_exhausted, false},
    {"a context overflow",
     %{
       "code" => "context_length_exceeded",
       "type" => "invalid_request_error",
       "message" => "Your input exceeds the context window of this model."
     }, 400, :context_overflow, false},
    {"a prompt the usage policy rejects",
     %{"code" => "invalid_prompt", "message" => "Invalid prompt: your prompt was flagged by our usage policy."}, 400,
     :invalid_request, false},
    {"a server error", %{"code" => "server_error", "type" => "server_error", "message" => "The server had an error."},
     500, :server_error, true},
    {"an overloaded server",
     %{"code" => "server_is_overloaded", "type" => "service_unavailable_error", "message" => "Try again later."}, 503,
     :server_error, true}
  ]

  @anthropic [
    {"an overload", %{"type" => "overloaded_error", "message" => "Overloaded"}, 529, :server_error, true},
    {"a rate limit", %{"type" => "rate_limit_error", "message" => "Slow down"}, 429, :rate_limit, true},
    {"a billing error", %{"type" => "billing_error", "message" => "Check your billing details"}, 402,
     :billing_exhausted, false},
    {"an invalid request", %{"type" => "invalid_request_error", "message" => "messages: bad role"}, 400,
     :invalid_request, false},
    {"a context overflow",
     %{"type" => "invalid_request_error", "message" => "prompt is too long: 210000 tokens > 200000 maximum"}, 400,
     :context_overflow, false}
  ]

  @gemini [
    {"an exhausted per-minute token quota",
     %{
       "code" => 429,
       "status" => "RESOURCE_EXHAUSTED",
       "message" => "Quota exceeded for metric: generate_content_free_tier_input_token_count, limit: 250000"
     }, 429, :rate_limit, true},
    {"depleted prepaid credits",
     %{"code" => 429, "status" => "RESOURCE_EXHAUSTED", "message" => "Your prepayment credits are depleted."}, 429,
     :billing_exhausted, false},
    {"an invalid argument",
     %{"code" => 400, "status" => "INVALID_ARGUMENT", "message" => "Request contains an invalid argument."}, 400,
     :invalid_request, false},
    {"a context overflow",
     %{
       "code" => 400,
       "status" => "INVALID_ARGUMENT",
       "message" => "The input token count (1200000) exceeds the maximum number of tokens allowed (1048576)."
     }, 400, :context_overflow, false},
    {"an unavailable model", %{"code" => 503, "status" => "UNAVAILABLE", "message" => "The model is overloaded."}, 503,
     :server_error, true},
    {"an error named only by its status", %{"status" => "PERMISSION_DENIED", "message" => "Permission denied."}, 403,
     :permission_denied, false}
  ]

  @moonshot [
    {"a content filter",
     %{"type" => "content_filter", "message" => "The request was rejected because it was considered high risk"}, 400,
     :content_filter, false},
    {"an exhausted quota", %{"type" => "exceeded_current_quota_error", "message" => "Token quota is insufficient"}, 429,
     :billing_exhausted, false},
    {"a rate limit", %{"type" => "rate_limit_reached_error", "message" => "Organization-level RPM limit reached"}, 429,
     :rate_limit, true},
    {"an overloaded engine",
     %{"type" => "engine_overloaded_error", "message" => "The engine is currently overloaded, please try again later"},
     429, :rate_limit, true},
    {"a context overflow", %{"type" => "invalid_request_error", "message" => "Input token length too long"}, 400,
     :context_overflow, false},
    {"a server error", %{"type" => "server_error", "message" => "Internal error"}, 500, :server_error, true}
  ]

  @zai [
    {"a content filter", %{"code" => "1301", "message" => "System detected potentially unsafe content."}, 400,
     :content_filter, false},
    {"a content filter with a numeric code", %{"code" => 1301, "message" => "System detected unsafe content."}, 400,
     :content_filter, false},
    {"an insufficient balance",
     %{"code" => "1113", "message" => "Insufficient balance or no resource package. Please recharge."}, 429,
     :billing_exhausted, false},
    {"a usage limit", %{"code" => "1308", "message" => "Usage limit reached for 5 hours."}, 429, :billing_exhausted,
     false},
    {"a rate limit", %{"code" => "1302", "message" => "Rate limit reached for requests"}, 429, :rate_limit, true},
    {"an overload", %{"code" => "1305", "message" => "The service may be temporarily overloaded"}, 429, :rate_limit,
     true},
    {"a prompt too long", %{"code" => "1261", "message" => "Prompt too long"}, 400, :context_overflow, false},
    {"an invalid parameter", %{"code" => "1214", "message" => "Parameter messages is invalid."}, 400, :invalid_request,
     false},
    {"a network error", %{"code" => "1234", "message" => "Network error, please try again later"}, 500, :server_error,
     true}
  ]

  @deepseek [
    {"a rate limit", %{"type" => "rate_limit_error", "message" => "Rate Limit Reached"}, 429, :rate_limit, true},
    {"an exhausted balance", %{"type" => "insufficient_quota", "message" => "Insufficient Balance"}, 429,
     :billing_exhausted, false},
    {"a context overflow",
     %{"type" => "invalid_request_error", "message" => "This model's maximum context length is 131072 tokens."}, 400,
     :context_overflow, false},
    {"an invalid request", %{"type" => "invalid_request_error", "message" => "Invalid format"}, 400, :invalid_request,
     false},
    {"an overloaded server", %{"type" => "service_unavailable_error", "message" => "Server Overloaded"}, 503,
     :server_error, true}
  ]

  for {provider, model, opts, format, cases} <- [
        {"OpenAI Responses", "openai:gpt-4.1", [], :responses, @openai},
        {"OpenAI Chat Completions", "openai:gpt-4.1", [api: :chat_completions], :chat_completions, @openai},
        {"xAI Responses", "xai:grok-4.3", [], :responses, @openai},
        {"xAI Chat Completions", "xai:grok-4.3", [api: :chat_completions], :chat_completions, @openai},
        {"Anthropic", "anthropic:claude-haiku-4-5", [], :anthropic, @anthropic},
        {"Gemini", "google:gemini-2.5-flash", [], :gemini, @gemini},
        {"Kimi", "moonshot:kimi-k2.6", [], :chat_completions, @moonshot},
        {"Z.ai", "zai:glm-5.2", [], :chat_completions, @zai},
        {"DeepSeek", "deepseek:deepseek-v4-flash", [], :chat_completions, @deepseek}
      ] do
    describe "#{provider}" do
      for {name, error, status, type, retryable?} <- cases do
        @tag model: model, opts: opts, format: format, error: error, status: status
        test "#{name} in a stream is the error it is without streaming", context do
          streamed = stream_error(context)

          assert {streamed.type, streamed.details.status, streamed.details.retryable} ==
                   {unquote(type), unquote(status), unquote(retryable?)}

          assert RetryPredicates.transient?(streamed) == unquote(retryable?)

          invoked = invoke_error(context)

          assert {invoked.type, invoked.details.status, invoked.details.retryable} ==
                   {unquote(type), unquote(status), unquote(retryable?)}

          assert streamed.message == invoked.message
        end

        @tag model: model, opts: opts, format: format, error: error, status: status
        test "#{name} in a streaming agent's reply is #{unless retryable?, do: "not "}retried by ModelRetry", context do
          assert {{:error, %Error{type: unquote(type)}}, requests} = run_agent(context)
          assert requests == if(unquote(retryable?), do: 3, else: 1)
        end
      end
    end
  end

  # Each API's answer to a wrong API key, which Gemini and xAI give with a 400.
  describe "a wrong API key" do
    @gemini_key_error %{
      "code" => 400,
      "status" => "INVALID_ARGUMENT",
      "message" => "API key not valid. Please pass a valid API key.",
      "details" => [%{"@type" => "type.googleapis.com/google.rpc.ErrorInfo", "reason" => "API_KEY_INVALID"}]
    }

    for {name, model, format, status, body} <- [
          {"OpenAI", "openai:gpt-4.1", :responses, 401,
           %{"error" => %{"code" => "invalid_api_key", "message" => "Incorrect API key provided."}}},
          {"Anthropic", "anthropic:claude-haiku-4-5", :anthropic, 401,
           %{"type" => "error", "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}}},
          {"Gemini", "google:gemini-2.5-flash", :gemini, 400, %{"error" => @gemini_key_error}},
          {"xAI", "xai:grok-4.3", :responses, 400,
           %{
             "code" => "invalid-argument",
             "error" => "Incorrect API key provided. You can obtain an API key from https://console.x.ai."
           }}
        ] do
      @tag model: model, opts: [], format: format, status: status, error: %{}, raw_body: body
      test "is an :authentication error from #{name}", context do
        context = Map.put(context, :error, nil)

        assert %Error{type: :authentication, details: %{retryable: false}} = error = invoke_raw_error(context)
        assert error.message =~ ~r/API key|x-api-key/
      end
    end
  end

  describe "OpenAI Responses error events" do
    @describetag model: "openai:gpt-4.1", opts: [], format: :responses, status: 400

    @tag error: %{"code" => "context_length_exceeded", "message" => "Your input exceeds the context window."},
         event: :nested
    test "an error event with a nested error object is classified by it", context do
      assert %Error{type: :context_overflow, details: %{status: 400, retryable: false}} = stream_error(context)
    end

    @tag error: %{"code" => "invalid_prompt", "message" => "Invalid prompt."}, event: :failed
    test "a failed response is the error its code names", context do
      assert %Error{type: :invalid_request, message: "Invalid prompt.", details: %{status: 400, retryable: false}} =
               stream_error(context)
    end

    @tag error: %{"code" => "server_error", "message" => "The model failed to generate a response."},
         event: :failed,
         status: 500
    test "a failed response with a server error can be retried", context do
      assert %Error{type: :server_error, details: %{status: 500, retryable: true}} = error = stream_error(context)
      assert RetryPredicates.transient?(error)
    end

    @tag error: %{"code" => "invalid_prompt", "message" => "Invalid prompt."}, event: :failed
    test "ModelRetry doesn't retry a failed response the usage policy rejected", context do
      assert {{:error, %Error{details: %{status: 400}}}, 1} = run_agent(context)
    end

    @tag error: %{"code" => "server_error", "message" => "The model failed to generate a response."},
         event: :failed,
         status: 500
    test "ModelRetry retries a failed response with a server error", context do
      assert {{:error, %Error{details: %{status: 500}}}, 3} = run_agent(context)
    end
  end

  # Runs a streaming agent with `ModelRetry` (two retries) on the model, and
  # counts its requests.
  defp run_agent(context) do
    {:ok, agent} =
      BeamWeaver.Agent.build(
        name: "orders",
        model: context.model,
        model_opts: [stream: true] ++ model_opts(context),
        middleware: [{ModelRetry, max_retries: 2}]
      )

    result = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is A-1001?"]})
    {result, requests()}
  end

  defp stream_error(context) do
    model = model(context)
    assert {:error, %Error{} = error} = model.__struct__.stream_response(model, [Message.user("Where is A-1001?")])

    assert {:ok, events} = ChatModel.stream_typed_events(model, [Message.user("Where is A-1001?")])
    assert [^error] = for(%{event: %BeamWeaver.Stream.Events.Error{error: error}} <- events, do: error)

    error
  end

  defp invoke_raw_error(context) do
    model =
      BeamWeaver.Models.init_chat_model!(context.model,
        api_key: "k",
        transport: Scripted,
        transport_opts: [
          parent: self(),
          status: context.status,
          http_body: BeamWeaver.JSON.encode!(context.raw_body),
          stream_body: ""
        ]
      )

    assert {:error, %Error{} = error} = ChatModel.invoke(model, [Message.user("Where is A-1001?")])
    error
  end

  defp invoke_error(context) do
    assert {:error, %Error{} = error} = ChatModel.invoke(model(context), [Message.user("Where is A-1001?")])
    error
  end

  defp model(context), do: BeamWeaver.Models.init_chat_model!(context.model, model_opts(context))

  defp model_opts(context) do
    [
      api_key: "k",
      transport: Scripted,
      transport_opts: [
        parent: self(),
        status: context.status,
        http_body: http_body(context.format, context.error),
        stream_body: cut_off(context.format, context.error, Map.get(context, :event, :flat))
      ]
    ] ++ context.opts
  end

  defp requests(count \\ 0) do
    receive do
      :request -> requests(count + 1)
    after
      0 -> count
    end
  end

  defp http_body(:anthropic, error), do: BeamWeaver.JSON.encode!(%{"type" => "error", "error" => error})
  defp http_body(_format, error), do: BeamWeaver.JSON.encode!(%{"error" => error})

  # A 200 stream that starts the answer, then reports the error the way the
  # API does.
  defp cut_off(:responses, error, event) do
    item = %{"id" => "msg_1", "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}
    response = %{"id" => "resp_1", "status" => "in_progress", "output" => []}

    failure =
      case event do
        :flat ->
          Map.merge(%{"type" => "error", "param" => nil}, Map.take(error, ["code", "message"]))

        :nested ->
          %{"type" => "error", "error" => error}

        :failed ->
          %{"type" => "response.failed", "response" => Map.merge(response, %{"status" => "failed", "error" => error})}
      end

    encode([
      %{"type" => "response.created", "response" => response},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => item},
      %{
        "type" => "response.output_text.delta",
        "item_id" => "msg_1",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => "It shipped on"
      },
      failure
    ])
  end

  defp cut_off(:chat_completions, error, _event) do
    encode([
      %{
        "id" => "chatcmpl_1",
        "model" => "m",
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => "It shipped on"}}]
      },
      %{"error" => error}
    ])
  end

  defp cut_off(:anthropic, error, _event) do
    message = %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5",
      "content" => [],
      "stop_reason" => nil,
      "usage" => %{"input_tokens" => 10}
    }

    encode([
      %{"type" => "message_start", "message" => message},
      %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
      %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "It shipped on"}},
      %{"type" => "error", "error" => error}
    ])
  end

  defp cut_off(:gemini, error, _event) do
    encode([
      %{
        "candidates" => [%{"index" => 0, "content" => %{"role" => "model", "parts" => [%{"text" => "It shipped on"}]}}]
      },
      %{"error" => error}
    ])
  end

  defp encode(events) do
    Enum.map_join(events, fn
      %{"type" => type} = data -> "event: #{type}\ndata: #{BeamWeaver.JSON.encode!(data)}\n\n"
      data -> "data: #{BeamWeaver.JSON.encode!(data)}\n\n"
    end)
  end
end
