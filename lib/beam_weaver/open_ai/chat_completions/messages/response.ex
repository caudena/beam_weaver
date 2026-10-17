defmodule BeamWeaver.OpenAI.ChatCompletions.Messages.Response do
  @moduledoc false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.Provider.ChatCompletionsWire

  def response_to_message(%{"error" => %{"message" => message} = error})
      when is_binary(message) do
    {:error, Error.new(:response_error, message, %{error: MessageParts.stringify_keys(error)})}
  end

  def response_to_message(%{"choices" => [choice | _rest]} = response) do
    message = choice["message"] || %{}

    Message.new(:assistant, content(message),
      id: response["id"],
      metadata: metadata(response, choice),
      response_metadata: metadata(response, choice),
      usage_metadata: usage_metadata(response),
      status: choice["finish_reason"],
      tool_calls: ChatCompletionsWire.tool_calls(message)
    )
  end

  def response_to_message(_response) do
    {:error, Error.new(:invalid_response, "OpenAI chat-completions response is invalid")}
  end

  defp metadata(response, choice) do
    message = choice["message"] || %{}
    header_metadata = response["_beamweaver_response_header_metadata"] || %{}

    %{
      id: response["id"],
      request_id: header_metadata[:request_id],
      model: response["model"],
      model_name: response["model"],
      model_provider: "openai",
      provider: :openai,
      usage: response["usage"],
      token_usage: response["usage"],
      finish_reason: choice["finish_reason"],
      system_fingerprint: response["system_fingerprint"],
      service_tier: response["service_tier"],
      provider_metadata: response["metadata"],
      moderation: response["moderation"],
      logprobs: choice["logprobs"],
      audio: message["audio"],
      headers: header_metadata[:headers],
      transport: BeamWeaver.Provider.ResponseDecoder.transport_metadata(header_metadata),
      raw_provider_response: response
    }
    |> MessageParts.reject_nil_values()
  end

  def usage_metadata(%{"usage" => usage}) when is_map(usage), do: MessageParts.usage_metadata(usage, :chat_completions)
  def usage_metadata(_response), do: nil

  defp content(%{"content" => content}) when is_binary(content), do: content
  defp content(%{"content" => content}) when is_list(content), do: Enum.map(content, &content_block/1)

  defp content(%{"refusal" => refusal}) when is_binary(refusal),
    do: [%{type: :refusal, refusal: refusal}]

  defp content(_message), do: ""

  defp content_block(%{"type" => type, "text" => text}) when type in ["text", "output_text"] do
    %{type: :text, text: text}
  end

  defp content_block(%{"type" => "refusal", "refusal" => refusal}) do
    %{type: :refusal, refusal: refusal}
  end

  defp content_block(block) when is_map(block) do
    %{
      type: block["type"],
      text: block["text"],
      refusal: block["refusal"],
      raw_provider_block: block
    }
    |> MessageParts.reject_nil_values()
  end
end
