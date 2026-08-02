defmodule BeamWeaver.DeepSeek.ContractTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.DeepSeek.ChatModel
  alias BeamWeaver.DeepSeek.Messages

  @chat_tool %{
    "type" => "function",
    "function" => %{
      "name" => "lookup",
      "description" => "Look something up",
      "parameters" => %{"type" => "object", "properties" => %{}}
    }
  }

  test "Chat rejects image, audio, video, and file content before transport" do
    blocks = [
      {ContentBlock.image(%{url: "https://example.test/image.png"}), :image},
      {ContentBlock.audio(%{data: "audio", mime_type: "audio/mpeg"}), :audio},
      {ContentBlock.video(%{data: "video", mime_type: "video/mp4"}), :video},
      {ContentBlock.file(%{data: "file", mime_type: "application/pdf"}), :file}
    ]

    for {block, feature} <- blocks do
      assert {:error, error} =
               ChatModel.request_body(ChatModel.new(), [Message.user([block])])

      assert error.type == :unsupported_feature
      assert error.details.feature == feature
      assert error.details.api == :chat_completions
    end
  end

  test "Chat enforces stop, tool-count, function-name, user-id, and ignored-parameter limits" do
    model = ChatModel.new()
    messages = [Message.user("hello")]

    assert {:error, stop_error} =
             ChatModel.request_body(model, messages, stop: List.duplicate("END", 17))

    assert stop_error.details.param == :stop

    assert {:error, tools_error} =
             ChatModel.request_body(model, messages, tools: List.duplicate(@chat_tool, 129))

    assert tools_error.details.max == 128

    invalid_name = put_in(@chat_tool, ["function", "name"], String.duplicate("a", 65))
    assert {:error, name_error} = ChatModel.request_body(model, messages, tools: [invalid_name])
    assert name_error.details.api == :chat_completions

    assert {:error, user_error} = ChatModel.request_body(model, messages, user_id: "invalid user")
    assert user_error.details.param == :user_id

    for param <- [:frequency_penalty, :presence_penalty] do
      assert {:error, error} =
               ChatModel.request_body(model, messages, model_kwargs: %{param => 0.5})

      assert error.type == :unsupported_model_param
      assert param in error.details.params
    end
  end

  test "Chat preserves every documented and provider-specific finish reason" do
    for finish_reason <- [
          "stop",
          "length",
          "tool_calls",
          "content_filter",
          "insufficient_system_resource",
          "future_finish_reason"
        ] do
      response = %{
        "id" => "chat-finish",
        "model" => "deepseek-v4-flash",
        "choices" => [
          %{
            "finish_reason" => finish_reason,
            "message" => %{"role" => "assistant", "content" => "done"}
          }
        ]
      }

      assert {:ok, message} = Messages.chat_response_to_message(response)
      assert message.status == finish_reason
      assert message.metadata.finish_reason == finish_reason
    end
  end

  test "Responses accepts no assistant message and preserves failed and unknown output items" do
    output = [
      %{
        "type" => "reasoning",
        "id" => "reasoning-1",
        "status" => "completed",
        "content" => [%{"type" => "reasoning_text", "text" => "searched"}]
      },
      %{
        "type" => "web_search_call",
        "id" => "search-1",
        "status" => "failed",
        "action" => %{"type" => "search", "query" => "DeepSeek"}
      },
      %{
        "type" => "future_deepseek_item",
        "id" => "future-1",
        "status" => "completed",
        "payload" => %{"kept" => true}
      }
    ]

    response = %{
      "id" => "response-1",
      "model" => "deepseek-v4-flash",
      "status" => "incomplete",
      "incomplete_details" => %{"reason" => "max_output_tokens"},
      "output" => output
    }

    assert {:ok, message} = Messages.responses_to_message(response)
    assert Message.text(message) == ""
    assert message.status == "incomplete"
    assert message.metadata.incomplete_details == %{"reason" => "max_output_tokens"}
    assert message.metadata.output == output
    assert message.metadata.raw_provider_response["output"] == output

    assert Enum.any?(message.content, fn
             %ContentBlock.Unknown{
               provider_type: "web_search_call",
               value: %{"status" => "failed", "action" => %{"query" => "DeepSeek"}}
             } ->
               true

             _block ->
               false
           end)
  end
end
