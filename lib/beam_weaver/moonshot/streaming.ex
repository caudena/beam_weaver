defmodule BeamWeaver.Moonshot.Streaming do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_optional: 3]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Moonshot.Messages, as: MoonshotMessages
  alias BeamWeaver.Provider.OpenAICompatibleStreaming

  @spec text_deltas(binary() | [map()] | term()) :: [String.t()]
  def text_deltas(body), do: OpenAICompatibleStreaming.text_deltas(body)

  @spec typed_events(binary() | [map()] | term()) :: [BeamWeaver.Stream.Envelope.t()]
  def typed_events(body), do: OpenAICompatibleStreaming.typed_events(body, config())

  # A live stream ends with the complete reply, the message
  # `stream_body_to_message/2` builds, which carries the `reasoning_content`
  # Kimi needs back with tool results, then the `Done` events.
  def typed_events(events, state), do: OpenAICompatibleStreaming.typed_events(events, state, config())

  def finish_typed_events(state, opts) do
    OpenAICompatibleStreaming.finish_typed_events(state, :moonshot, fn events ->
      with {:ok, message} <- OpenAICompatibleStreaming.events_to_message(events, config(), opts),
           do: {:ok, MoonshotMessages.enrich_cache_write_ttl(message)}
    end)
  end

  @spec stream_body_to_message(binary(), keyword()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, Error.t()}
  def stream_body_to_message(body, opts \\ [])

  def stream_body_to_message(body, opts) do
    case OpenAICompatibleStreaming.stream_body_to_message(body, config(), opts) do
      {:ok, message} -> {:ok, MoonshotMessages.enrich_cache_write_ttl(message)}
      other -> other
    end
  end

  defp stream_metadata(events, message, opts) do
    reasoning_content = reasoning_content(message)

    events
    |> Enum.reduce(%{model_provider: "moonshot", provider: :moonshot}, fn
      %{"data" => data}, acc when is_map(data) ->
        choice = first_choice(data)

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
    |> put_headers(opts)
  end

  defp put_headers(metadata, opts) do
    header_metadata = Keyword.get(opts, :header_metadata, %{})

    metadata
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

  defp first_choice(%{"choices" => [choice | _rest]}) when is_map(choice), do: choice
  defp first_choice(_data), do: nil

  defp reasoning_content(%{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "reasoning", "reasoning" => text} when is_binary(text) -> [text]
      %{type: :reasoning, reasoning: text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("")
    |> empty_to_nil()
  end

  defp reasoning_content(_message), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp config do
    %{
      provider: :moonshot,
      provider_name: "Moonshot chat-completions",
      usage_metadata: &MoonshotMessages.usage_metadata/1,
      stream_metadata: &stream_metadata/3,
      choice_usage: true,
      include_chunk_id: false,
      reasoning_index: 0,
      unknown_delta_key: :moonshot_delta
    }
  end
end
