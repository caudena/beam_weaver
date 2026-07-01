defmodule BeamWeaver.OpenAI.ChatCompletions.Messages.Response do
  @moduledoc false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.OpenAI.MessageParts

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
      tool_calls: tool_calls(message)
    )
    |> case do
      {:ok, message} -> {:ok, message}
      {:error, error} -> {:error, Error.new(error.type, error.message, error.details)}
    end
  end

  def response_to_message(_response) do
    {:error, Error.new(:invalid_response, "OpenAI chat-completions response is invalid")}
  end

  def metadata(response, choice) do
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
      logprobs: choice["logprobs"],
      audio: message["audio"],
      headers: header_metadata[:headers],
      transport: transport_metadata(header_metadata),
      raw_provider_response: response
    }
    |> MessageParts.reject_nil_values()
  end

  defp transport_metadata(%{request_id: request_id}) when is_binary(request_id) and request_id != "" do
    %{request_id: request_id}
  end

  defp transport_metadata(_metadata), do: nil

  def usage_metadata(%{"usage" => usage}) when is_map(usage) do
    %{
      input_tokens: usage["prompt_tokens"] || usage["input_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || usage["output_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0,
      input_token_details: input_token_details(usage),
      output_token_details: output_token_details(usage)
    }
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

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

  defp tool_calls(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    Enum.map(tool_calls, fn call ->
      function = call["function"] || %{}

      Messages.tool_call(
        id: call["id"],
        provider_id: call["id"],
        call_id: call["id"],
        name: function["name"],
        args: decode_arguments(function["arguments"])
      )
    end)
  end

  defp tool_calls(_message), do: []

  defp decode_arguments(arguments) when is_binary(arguments) do
    case BeamWeaver.JSON.decode(arguments) do
      {:ok, decoded} -> decoded
      {:error, _error} -> arguments
    end
  end

  defp decode_arguments(arguments), do: arguments

  defp input_token_details(usage) when is_map(usage) do
    case usage["prompt_tokens_details"] || usage["input_tokens_details"] do
      details when is_map(details) ->
        %{
          cache_read: details["cached_tokens"],
          flex: details["flex"]
        }
        |> BeamWeaver.MapShape.reject_nil_or_empty()

      _details ->
        %{}
    end
  end

  defp output_token_details(usage) when is_map(usage) do
    case usage["completion_tokens_details"] || usage["output_tokens_details"] do
      details when is_map(details) ->
        %{
          reasoning: details["reasoning_tokens"],
          accepted_prediction: details["accepted_prediction_tokens"],
          rejected_prediction: details["rejected_prediction_tokens"],
          flex: details["flex"],
          flex_reasoning: details["flex_reasoning"]
        }
        |> BeamWeaver.MapShape.reject_nil_or_empty()

      _details ->
        %{}
    end
  end
end
