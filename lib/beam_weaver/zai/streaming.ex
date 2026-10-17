defmodule BeamWeaver.ZAI.Streaming do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_optional: 3]

  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.ZAI.Messages, as: ZAIMessages

  # A live stream ends with the complete reply, the message
  # `OpenAICompatibleStreaming` builds with this config, with its reasoning
  # and priced usage, then the `Done` events.
  def config do
    %{
      provider: :zai,
      provider_name: "Z.ai chat-completions",
      usage_metadata: &ZAIMessages.usage_metadata/1,
      stream_metadata: &stream_metadata/3,
      finish_message: &price_stream_usage/1,
      choice_usage: false,
      include_chunk_id: true,
      reasoning_index: 0,
      unknown_delta_key: :zai_delta
    }
  end

  defp price_stream_usage(message) do
    metadata = message.response_metadata
    model = metadata[:model]
    raw_usage = metadata[:token_usage]

    if is_binary(model) and is_map(raw_usage) do
      usage =
        ZAIMessages.usage_metadata(%{
          "model" => model,
          "created" => metadata[:created],
          "usage" => raw_usage
        })

      %{message | usage_metadata: usage, response_metadata: Map.put(metadata, :usage, usage)}
    else
      message
    end
  end

  defp stream_metadata(events, message, opts) do
    reasoning_content = ChatCompletionsWire.content_reasoning(message.content)
    header_metadata = Keyword.get(opts, :header_metadata, %{})
    decoded_headers = header_metadata[:headers] || %{}
    x_log_id = decoded_headers[:x_log_id]

    events
    |> Enum.reduce(%{model_provider: "zai", provider: :zai, api: :chat_completions}, fn
      %{"data" => data}, acc when is_map(data) ->
        choice = ChatCompletionsWire.first_choice(data)
        id = data["id"] || acc[:id] || x_log_id

        acc
        |> put_optional(:id, id)
        |> put_optional(:request_id, data["request_id"] || id)
        |> put_optional(:x_log_id, x_log_id)
        |> put_optional(:created, data["created"])
        |> put_optional(:object, data["object"])
        |> put_optional(:model, data["model"])
        |> put_optional(:model_name, data["model"])
        |> put_optional(:token_usage, data["usage"])
        |> put_optional(:finish_reason, choice && choice["finish_reason"])

      _event, acc ->
        acc
    end)
    |> put_optional(:reasoning_content, reasoning_content)
    |> put_optional(:headers, header_metadata[:headers])
    |> put_optional(:transport, BeamWeaver.Provider.ResponseDecoder.transport_metadata(header_metadata))
    |> maybe_put_raw_headers(
      Keyword.get(opts, :raw_response_headers, []),
      Keyword.get(opts, :include_response_headers, false)
    )
  end

  defp maybe_put_raw_headers(metadata, _headers, false), do: metadata

  defp maybe_put_raw_headers(metadata, headers, true) do
    put_optional(metadata, :_beamweaver_response_headers, Map.new(headers))
  end
end
