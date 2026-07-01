defmodule BeamWeaver.Provider.CapabilityResponseTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.MapShape
  alias BeamWeaver.Models
  alias BeamWeaver.Provider.Response

  test "unsupported rich features fail before a transport call by default" do
    assert {:ok, model} =
             Models.init_chat_model("xai:grok-4.20-0309-non-reasoning",
               reasoning_effort: "high",
               transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
               transport_opts: [parent: self()]
             )

    assert {:error, error} = ChatModel.invoke(model, "think")
    assert error.type == :unsupported_feature
    assert error.details.provider == :xai
    assert error.details.feature == :reasoning
    refute_received {:fake_transport_request, _request}
  end

  test "unsupported rich features can warn or be ignored explicitly" do
    assert {:ok, model} =
             Models.init_chat_model("xai:grok-4.20-0309-non-reasoning",
               reasoning_effort: "high",
               transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
               transport_opts: [
                 parent: self(),
                 expect: %{method: :post, path: "/v1/responses"},
                 body: %{
                   "id" => "resp_warn",
                   "model" => "grok-4.20-0309-non-reasoning",
                   "status" => "completed",
                   "output" => [
                     %{
                       "type" => "message",
                       "role" => "assistant",
                       "content" => [%{"type" => "output_text", "text" => "ok"}]
                     }
                   ],
                   "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
                 }
               ]
             )

    assert {:ok, response} = ChatModel.invoke(model, "think", unsupported: :warn)
    assert Message.text(response) == "ok"
    assert_received {:fake_transport_request, _request}
  end

  test "unsupported policy rejects string enum values" do
    assert {:ok, model} =
             Models.init_chat_model("xai:grok-4.20-0309-non-reasoning",
               reasoning_effort: "high",
               transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
               transport_opts: [parent: self()]
             )

    assert {:error, error} = ChatModel.invoke(model, "think", unsupported: "warn")
    assert error.type == :invalid_provider_option
    assert error.message == ~s(unsupported must be an atom, got "warn"; use :warn)
    refute_received {:fake_transport_request, _request}
  end

  test "response normalization preserves public usage while exposing trace metadata" do
    assert {:ok, model} = Models.init_chat_model("fake:chat")

    message =
      Message.assistant("pong",
        usage_metadata: %{
          input_tokens: 2,
          output_tokens: 3,
          total_tokens: 5,
          input_token_details: %{cache_read: 1, cache_creation_tokens: 2},
          output_token_details: %{reasoning: 4}
        },
        response_metadata: %{
          model_provider: "fake",
          id: "resp_123",
          finish_reason: "stop",
          request_id: "req_123",
          transport: %{request_id: "req_123"},
          limits: %{remaining_tokens: "99"}
        }
      )

    normalized = Response.normalize_message(model, message)

    assert normalized.usage_metadata == %{
             input_tokens: 2,
             output_tokens: 3,
             total_tokens: 5,
             input_token_details: %{cache_read: 1, cache_creation_tokens: 2},
             output_token_details: %{reasoning: 4}
           }

    assert normalized.response_metadata.usage.input_tokens == 2
    assert normalized.response_metadata.usage.cache_read_tokens == 1
    assert normalized.response_metadata.usage.cache_creation_tokens == 2
    assert normalized.response_metadata.usage.reasoning_tokens == 4
    assert MapShape.assert_atom_keys_deep!(normalized.response_metadata.usage)
    assert normalized.response_metadata.model.provider == :fake
    assert normalized.response_metadata.transport.request_id == "req_123"
    assert normalized.response_metadata.limits.remaining_tokens == "99"
  end

  test "response normalization preserves client-provided decoded headers and limits" do
    model = %{provider: :anthropic, model: "claude-sonnet-5"}

    message =
      Message.assistant("pong",
        response_metadata: %{
          model_provider: "anthropic",
          provider: :anthropic,
          model: "claude-sonnet-5",
          headers: %{
            request_id: "req_anthropic",
            anthropic_organization_id: "org_123",
            anthropic_ratelimit_requests_remaining: "49",
            anthropic_ratelimit_tokens_remaining: "999"
          },
          request_id: "req_anthropic",
          transport: %{request_id: "req_anthropic"},
          limits: %{
            remaining_requests: "49",
            remaining_tokens: "999"
          }
        }
      )

    normalized = Response.normalize_message(model, message)

    assert normalized.response_metadata.headers == %{
             request_id: "req_anthropic",
             anthropic_organization_id: "org_123",
             anthropic_ratelimit_requests_remaining: "49",
             anthropic_ratelimit_tokens_remaining: "999"
           }

    assert normalized.response_metadata.request_id == "req_anthropic"
    assert normalized.response_metadata.transport.request_id == "req_anthropic"
    assert normalized.response_metadata.limits.remaining_requests == "49"
    assert normalized.response_metadata.limits.remaining_tokens == "999"
  end
end
