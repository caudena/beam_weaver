defmodule BeamWeaver.OpenAI.ChatCompletions.Messages.Stream do
  @moduledoc false

  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.OpenAI.ChatCompletions.Messages.Response
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.OpenAI.MessageParts

  def stream_body_to_message(body) when is_binary(body) do
    events = BeamWeaver.OpenAI.Streaming.events(body)
    chunks = BeamWeaver.OpenAI.Streaming.message_chunks(events)

    case MessageChunk.merge_many(chunks) do
      nil ->
        {:error, Error.new(:invalid_response, "OpenAI chat-completions stream had no chunks")}

      chunk ->
        message = MessageChunk.to_message(chunk)
        usage = stream_usage(events)
        finish_reason = stream_finish_reason(events)

        {:ok,
         %{
           message
           | usage_metadata: usage,
             status: finish_reason,
             response_metadata:
               message.response_metadata
               |> Map.merge(stream_metadata(events))
               |> Map.merge(%{usage: usage, finish_reason: finish_reason})
               |> MessageParts.reject_nil_values()
         }}
    end
  end

  def stream_body_to_message(_body) do
    {:error, Error.new(:invalid_response, "OpenAI chat-completions stream body must be binary")}
  end

  defp stream_metadata(events) do
    events
    |> Enum.reduce(%{}, fn
      %{"data" => data}, acc when is_map(data) ->
        choice = first_choice(data)

        acc
        |> put_optional(:id, data["id"])
        |> put_optional(:model, data["model"])
        |> put_optional(:model_name, data["model"])
        |> put_optional(:model_provider, "openai")
        |> put_optional(:provider, :openai)
        |> put_optional(:system_fingerprint, data["system_fingerprint"])
        |> put_optional(:service_tier, data["service_tier"])
        |> put_optional(:token_usage, data["usage"])
        |> put_optional(:logprobs, choice && choice["logprobs"])

      _event, acc ->
        acc
    end)
  end

  defp first_choice(%{"choices" => [choice | _rest]}) when is_map(choice), do: choice
  defp first_choice(_data), do: nil

  defp stream_usage(events) do
    events
    |> Enum.find_value(fn
      %{"data" => %{"usage" => usage}} when is_map(usage) ->
        Response.usage_metadata(%{"usage" => usage})

      _event ->
        nil
    end)
  end

  defp stream_finish_reason(events) do
    events
    |> Enum.find_value(fn
      %{"data" => %{"choices" => choices}} when is_list(choices) ->
        Enum.find_value(choices, & &1["finish_reason"])

      _event ->
        nil
    end)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, []), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
