defmodule BeamWeaver.Models.InitializerConfigTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.Models
  alias BeamWeaver.TestSupport.ConfigHelper

  defmodule RecordingTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:transport_request, request})
      {:ok, BeamWeaver.Transport.Response.new(status: 200, headers: [], body: "{}")}
    end
  end

  test "init_chat_model applies configured provider API keys" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:google, api_key: "google-config-secret")
    BeamWeaver.TestSupport.ConfigHelper.put_config(:openai, api_key: "openai-config-secret")

    assert {:ok, google} = Models.init_chat_model("google:gemini-3.5-flash")
    assert google.api_key == "google-config-secret"
    assert Models.init_chat_model!("google:gemini-3.5-flash").api_key == "google-config-secret"

    assert {:ok, openai} = Models.init_chat_model("openai:gpt-5.4")
    assert openai.api_key == "openai-config-secret"
  end

  test "init_chat_model keeps explicit nil API keys explicit" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:google, api_key: "google-config-secret")

    assert {:ok, google} = Models.init_chat_model("google:gemini-3.5-flash", api_key: nil)
    assert google.api_key == nil
  end

  test "init_embeddings applies the configured OpenAI API key" do
    ConfigHelper.put_config(:openai, api_key: "openai-config-secret")

    model = Models.init_embeddings!("openai:text-embedding-3-small", transport_opts())
    EmbeddingModel.embed_query(model, "refunds")

    assert_received {:transport_request, request}
    assert {"authorization", "Bearer openai-config-secret"} in request.headers
  end

  test "OpenAI and Anthropic models use the configured base_url" do
    ConfigHelper.put_config(:openai, api_key: "openai-key", base_url: "http://localhost:4010/openai/v1")
    ConfigHelper.put_config(:anthropic, api_key: "anthropic-key", base_url: "http://localhost:4010/anthropic")

    for {id, opts, url} <- [
          {"openai:gpt-5.4-mini", [], "http://localhost:4010/openai/v1/responses"},
          {"openai:gpt-5.4-mini", [api: :chat_completions], "http://localhost:4010/openai/v1/chat/completions"},
          {"anthropic:claude-haiku-4-5", [], "http://localhost:4010/anthropic/v1/messages"}
        ] do
      model = Models.init_chat_model!(id, opts ++ transport_opts())
      ChatModel.invoke(model, "Where is my order A-1001?")

      assert_received {:transport_request, %{url: ^url}}
    end

    anthropic = Models.init_chat_model!("anthropic:claude-haiku-4-5")
    assert anthropic.count_tokens_endpoint == "http://localhost:4010/anthropic/v1/messages/count_tokens"

    embeddings = Models.init_embeddings!("openai:text-embedding-3-small", transport_opts())
    EmbeddingModel.embed_query(embeddings, "refunds")
    assert_received {:transport_request, %{url: "http://localhost:4010/openai/v1/embeddings"}}
  end

  test "a base_url option wins over the configured one" do
    ConfigHelper.put_config(:openai, api_key: "openai-key", base_url: "http://localhost:4010/configured/v1")
    ConfigHelper.put_config(:anthropic, api_key: "anthropic-key")

    model = Models.init_chat_model!("openai:gpt-5.4-mini", [base_url: "http://localhost:4011/v1"] ++ transport_opts())
    ChatModel.invoke(model, "hi")
    assert_received {:transport_request, %{url: "http://localhost:4011/v1/responses"}}

    model =
      Models.init_chat_model!("anthropic:claude-haiku-4-5", [base_url: "http://localhost:4011"] ++ transport_opts())

    ChatModel.invoke(model, "hi")
    assert_received {:transport_request, %{url: "http://localhost:4011/v1/messages"}}
  end

  defp transport_opts, do: [transport: RecordingTransport, transport_opts: [parent: self()]]
end
