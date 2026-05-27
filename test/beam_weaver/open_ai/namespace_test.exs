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
end
