defmodule BeamWeaver.Agent.ModelFallbackTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.ModelFallback
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Transport.Response

  defmodule StringFallbackAgent do
    use BeamWeaver.Agent

    model "fake:chat", error: BeamWeaver.Core.Error.new(:provider_error, "Service unavailable")
    middleware [{ModelFallback, fallbacks: ["fake:chat"]}]
  end

  test "a \"provider:model\" string in fallbacks is resolved like the agent's model" do
    assert {:ok, result} = StringFallbackAgent.invoke(%{messages: ["Where is my order A-1001?"]})
    assert [%Message{role: :user}, %Message{role: :assistant}] = result.messages

    assert %ModelFallback{fallbacks: [%BeamWeaver.OpenAI.ChatModel{}, %FakeChatModel{}]} =
             ModelFallback.new(fallbacks: ["openai:gpt-5.4-mini", "fake:chat"])
  end

  test "an unknown fallback model fails when the middleware is built" do
    assert_raise ArgumentError, ~r/invalid fallback model "nope:model"/, fn ->
      ModelFallback.new(fallbacks: ["nope:model"])
    end
  end

  defmodule OverloadedTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:primary_request, request.url, request.headers})
      {:ok, Response.new(status: 503, body: ~s({"error":{"message":"overloaded"}}))}
    end
  end

  defmodule ClaudeTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:fallback_request, request.url, request.headers, request.json})

      body = %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-haiku-4-5",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
        "content" => [%{"type" => "text", "text" => "Order A-1001 shipped on Monday."}]
      }

      {:ok, Response.new(status: 200, body: BeamWeaver.JSON.encode!(body))}
    end
  end

  test "a fallback of another provider keeps its own key and transport and gets only the options it takes" do
    fallback =
      Models.init_chat_model!("anthropic:claude-haiku-4-5",
        api_key: "sk-ant-fallback",
        transport: ClaudeTransport,
        transport_opts: [parent: self()]
      )

    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: "openai:gpt-5.4-mini",
        model_opts: [
          reasoning_effort: :low,
          temperature: 0.2,
          api_key: "sk-openai-primary",
          transport: OverloadedTransport,
          transport_opts: [parent: self()]
        ],
        middleware: [{ModelFallback, fallbacks: [fallback]}]
      )

    assert {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001?"]})
    assert List.last(result.messages).content == "Order A-1001 shipped on Monday."

    assert_received {:primary_request, "https://api.openai.com/v1/responses", _headers}
    assert_received {:fallback_request, "https://api.anthropic.com/v1/messages", headers, body}
    refute_received {:primary_request, _url, _headers}

    assert {"x-api-key", "sk-ant-fallback"} in headers
    refute inspect(headers) =~ "sk-openai-primary"
    assert body["temperature"] == 0.2
    refute Map.has_key?(body, "reasoning_effort")
  end

  test "a fallback is called with the agent's own options and the model parameters its profile takes" do
    primary = Models.init_chat_model!("openai:gpt-5.4-mini")
    fallback = Models.init_chat_model!("anthropic:claude-haiku-4-5", api_key: "sk-ant-fallback")
    middleware = ModelFallback.new(fallbacks: [fallback])

    request =
      ModelRequest.new(
        model: primary,
        messages: [Message.user("hello")],
        model_opts: [
          api_key: "sk-openai-primary",
          base_url: "https://openai.example/v1",
          endpoint: "https://openai.example/v1/responses",
          organization: "org-1",
          transport: OverloadedTransport,
          transport_opts: [parent: self()],
          timeout: 60_000,
          extra_body: %{"store" => false},
          model: "gpt-5.4",
          reasoning_effort: :low,
          prompt_cache_key: "thread-1",
          temperature: 0.2,
          max_tokens: 1_000,
          tools: [%{type: "web_search"}],
          context: %{tenant: "acme"},
          assistant_name: "support"
        ]
      )

    handler = fn
      %ModelRequest{model: ^primary} -> {:error, Error.new(:provider_error, "overloaded")}
      %ModelRequest{} = fallback_request -> {:ok, fallback_request}
    end

    assert {:ok, %ModelRequest{model: ^fallback, model_opts: opts}} =
             ModelFallback.wrap_model_call(middleware, request, handler)

    assert Enum.sort(opts) == [
             assistant_name: "support",
             context: %{tenant: "acme"},
             max_tokens: 1_000,
             temperature: 0.2,
             tools: []
           ]

    # A fallback of the same kind keeps the provider's built-in tools and the
    # parameters it takes, but still not the primary's connection settings.
    same_kind = Models.init_chat_model!("openai:gpt-5.4", api_key: "sk-openai-fallback")

    assert {:ok, %ModelRequest{model: ^same_kind, model_opts: opts}} =
             ModelFallback.wrap_model_call(ModelFallback.new(fallbacks: [same_kind]), request, handler)

    assert Enum.sort(opts) == [
             assistant_name: "support",
             context: %{tenant: "acme"},
             max_tokens: 1_000,
             prompt_cache_key: "thread-1",
             reasoning_effort: :low,
             temperature: 0.2,
             tools: [%{type: "web_search"}]
           ]
  end
end
