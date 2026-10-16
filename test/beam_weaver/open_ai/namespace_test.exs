defmodule BeamWeaver.OpenAI.NamespaceTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.OpenAI
  alias BeamWeaver.OpenAI.Client

  setup do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:openai, [])

    :ok
  end

  test "constructors load OpenAI config defaults unless explicit opts are supplied" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:openai,
      api_key: "sk-env",
      organization: "org-env",
      project: "proj-env"
    )

    model = OpenAI.chat_model(endpoint: "https://proxy.example/v1/responses")

    assert model.api_key == "sk-env"
    assert model.organization == "org-env"
    assert model.project == "proj-env"
    assert model.endpoint == "https://proxy.example/v1/responses"

    explicit =
      OpenAI.chat_model(api_key: nil, organization: "org-explicit", project: "proj-explicit")

    assert explicit.api_key == nil
    assert explicit.organization == "org-explicit"
    assert explicit.project == "proj-explicit"
  end

  test "constructors preserve explicit endpoints" do
    assert OpenAI.responses_model(endpoint: "https://gateway.example/openai/responses").endpoint ==
             "https://gateway.example/openai/responses"

    assert OpenAI.chat_completions_model(endpoint: "https://gateway.example/openai/chat/completions").endpoint ==
             "https://gateway.example/openai/chat/completions"

    assert OpenAI.embedding_model(endpoint: "https://gateway.example/openai/embeddings").endpoint ==
             "https://gateway.example/openai/embeddings"
  end

  test "client resolves lazy api keys at the transport request boundary" do
    parent = self()

    client = %Client{
      endpoint: "https://api.openai.test/v1/responses",
      api_key: fn ->
        send(parent, :api_key_resolved)
        "sk-lazy"
      end
    }

    request = Client.request(client, %{"model" => "gpt-5.4-mini", "input" => []})

    assert {"authorization", "Bearer sk-lazy"} in request.headers
    assert_received :api_key_resolved
  end

  describe "custom endpoints reach the transport" do
    @transport BeamWeaver.TestSupport.Conformance.Fakes.Transport
    @chat_completion %{
      "id" => "chatcmpl_fake",
      "object" => "chat.completion",
      "choices" => [
        %{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
    }

    test "chat completions model posts to its configured endpoint" do
      model =
        OpenAI.chat_completions_model(
          endpoint: "https://gateway.example/openai/chat/completions",
          api_key: "sk-test",
          transport: @transport,
          transport_opts: [parent: self(), body: @chat_completion]
        )

      assert {:ok, _message} = BeamWeaver.Core.ChatModel.invoke(model, [BeamWeaver.Core.Message.user("hi")])
      assert_received {:fake_transport_request, request}
      assert request.url == "https://gateway.example/openai/chat/completions"
    end

    test "client derives chat completions and response URLs from base_url" do
      client =
        Client.new(
          base_url: "https://gateway.example/v1/",
          api_key: "sk-test",
          transport: @transport,
          transport_opts: [parent: self(), body: @chat_completion]
        )

      assert {:ok, _body} = Client.chat_completions(client, %{"model" => "gpt-5.4-mini", "messages" => []})
      assert_received {:fake_transport_request, %{url: "https://gateway.example/v1/chat/completions"}}

      assert {:ok, _body} = Client.retrieve_response(client, "resp_1")
      assert_received {:fake_transport_request, %{url: "https://gateway.example/v1/responses/resp_1"}}
    end

    test "moderation posts under the middleware client's base_url" do
      client =
        Client.new(
          base_url: "https://gateway.example/v1",
          api_key: "sk-test",
          transport: @transport,
          transport_opts: [parent: self(), body: %{"results" => [%{"flagged" => false}]}]
        )

      middleware = OpenAI.moderation_middleware(client: client)

      assert {:ok, %{"flagged" => false}} = BeamWeaver.OpenAI.ModerationMiddleware.moderate(middleware, "hello")
      assert_received {:fake_transport_request, %{url: "https://gateway.example/v1/moderations"}}
    end
  end
end
