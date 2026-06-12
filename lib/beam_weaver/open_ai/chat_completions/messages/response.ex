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

    %{
      id: response["id"],
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
      raw_provider_response: response
    }
    |> MessageParts.reject_nil_values()
  end

  def usage_metadata(%{"usage" => usage}) when is_map(usage) do
    %{
      input_tokens: usage["prompt_tokens"] || usage["input_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || usage["output_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0
    }
    |> put_usage_details(:input_token_details, input_token_details(usage))
    |> put_usage_details(:output_token_details, output_token_details(usage))
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

  defp input_token_details(%{"prompt_tokens_details" => details}) when is_map(details) do
    %{}
    |> put_detail(:cache_read, details["cached_tokens"])
    |> put_detail(:flex, details["flex"])
  end

  defp input_token_details(%{"input_tokens_details" => details}) when is_map(details) do
    %{}
    |> put_detail(:cache_read, details["cached_tokens"])
    |> put_detail(:flex, details["flex"])
  end

  defp input_token_details(_usage), do: %{}

  defp output_token_details(%{"completion_tokens_details" => details}) when is_map(details) do
    %{}
    |> put_detail(:reasoning, details["reasoning_tokens"])
    |> put_detail(:accepted_prediction, details["accepted_prediction_tokens"])
    |> put_detail(:rejected_prediction, details["rejected_prediction_tokens"])
    |> put_detail(:flex, details["flex"])
    |> put_detail(:flex_reasoning, details["flex_reasoning"])
  end

  defp output_token_details(%{"output_tokens_details" => details}) when is_map(details) do
    %{}
    |> put_detail(:reasoning, details["reasoning_tokens"])
    |> put_detail(:accepted_prediction, details["accepted_prediction_tokens"])
    |> put_detail(:rejected_prediction, details["rejected_prediction_tokens"])
    |> put_detail(:flex, details["flex"])
    |> put_detail(:flex_reasoning, details["flex_reasoning"])
  end

  defp output_token_details(_usage), do: %{}

  defp put_usage_details(metadata, _key, details) when details == %{}, do: metadata
  defp put_usage_details(metadata, key, details), do: Map.put(metadata, key, details)

  defp put_detail(details, _key, nil), do: details
  defp put_detail(details, key, value), do: Map.put(details, key, value)
end
