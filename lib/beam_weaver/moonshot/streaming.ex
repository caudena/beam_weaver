defmodule BeamWeaver.Moonshot.Streaming do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_optional: 3]

  alias BeamWeaver.Moonshot.Messages, as: MoonshotMessages
  alias BeamWeaver.Provider.ChatCompletionsWire

  # A live stream ends with the complete reply, the message
  # `OpenAICompatibleStreaming` builds with this config, which carries the
  # `reasoning_content` Kimi needs back with tool results, then the `Done`
  # events.
  def config do
    %{
      provider: :moonshot,
      provider_name: "Moonshot chat-completions",
      usage_metadata: &MoonshotMessages.usage_metadata/1,
      stream_metadata: &stream_metadata/3,
      finish_message: &MoonshotMessages.enrich_cache_write_ttl/1,
      choice_usage: true,
      include_chunk_id: false,
      reasoning_index: 0,
      unknown_delta_key: :moonshot_delta
    }
  end

  defp stream_metadata(events, message, opts) do
    reasoning_content = ChatCompletionsWire.content_reasoning(message.content)
    header_metadata = Keyword.get(opts, :header_metadata, %{})

    events
    |> Enum.reduce(%{model_provider: "moonshot", provider: :moonshot}, fn
      %{"data" => data}, acc when is_map(data) ->
        choice = ChatCompletionsWire.first_choice(data)

        acc
        |> put_optional(:id, data["id"])
        |> put_optional(:model, data["model"])
        |> put_optional(:model_name, data["model"])
        |> put_optional(:system_fingerprint, data["system_fingerprint"])
        |> put_optional(:service_tier, data["service_tier"])
        |> put_optional(:token_usage, data["usage"] || (choice && choice["usage"]))
        |> put_optional(:logprobs, choice && choice["logprobs"])

      _event, acc ->
        acc
    end)
    |> put_optional(:reasoning_content, reasoning_content)
    |> put_optional(:headers, header_metadata[:headers])
    |> put_optional(:request_id, header_metadata[:request_id])
    |> put_optional(:transport, BeamWeaver.Provider.ResponseDecoder.transport_metadata(header_metadata))
    |> maybe_put_raw_headers(
      Keyword.get(opts, :raw_response_headers, []),
      Keyword.get(opts, :include_response_headers, false)
    )
  end

  defp maybe_put_raw_headers(metadata, _headers, false), do: metadata

  defp maybe_put_raw_headers(metadata, headers, true) do
    put_optional(
      metadata,
      :_beamweaver_response_headers,
      Map.new(BeamWeaver.Transport.Request.normalize_headers(headers))
    )
  end
end
