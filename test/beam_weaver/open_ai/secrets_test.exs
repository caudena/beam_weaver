defmodule BeamWeaver.OpenAI.SecretsTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.OpenAI
  alias BeamWeaver.OpenAI.ChatCompletionsModel
  alias BeamWeaver.OpenAI.ChatModel
  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.OpenAI.EmbeddingModel
  alias BeamWeaver.OpenAI.ModerationMiddleware
  alias BeamWeaver.OpenAI.ResponsesModel
  alias BeamWeaver.Transport.Redactor

  setup do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:openai, [])
    :ok
  end

  test "OpenAI provider structs redact API keys when inspected" do
    structs = [
      %Client{api_key: "sk-secret-client"},
      %ChatModel{api_key: "sk-secret-chat"},
      %ResponsesModel{api_key: "sk-secret-responses"},
      %ChatCompletionsModel{api_key: "sk-secret-completions"},
      %EmbeddingModel{api_key: "sk-secret-embedding"},
      ModerationMiddleware.new(api_key: "sk-secret-moderation")
    ]

    for struct <- structs do
      inspected = inspect(struct)

      refute inspected =~ "sk-secret"
      assert inspected =~ Redactor.redacted()
    end
  end

  test "configured API keys are loaded but not exposed by Inspect" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:openai, api_key: "sk-env-secret")

    model = OpenAI.chat_model()

    assert model.api_key == "sk-env-secret"
    inspected = inspect(model, limit: :infinity)
    refute inspected =~ "sk-env-secret"
    assert inspected =~ Redactor.redacted()
  end

  test "request headers use the actual lazy secret at the transport boundary" do
    parent = self()

    client = %Client{
      api_key: fn ->
        send(parent, :resolved_api_key)
        "sk-lazy-secret"
      end
    }

    request = Client.request(client, %{"model" => "gpt-5.4-mini", "input" => []})

    assert {"authorization", "Bearer sk-lazy-secret"} in request.headers
    assert_received :resolved_api_key

    inspected = inspect(client)
    refute inspected =~ "sk-lazy-secret"
    assert inspected =~ Redactor.redacted()
  end
end
