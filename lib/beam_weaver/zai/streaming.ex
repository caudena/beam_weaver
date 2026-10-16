defmodule BeamWeaver.ZAI.Streaming do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_optional: 3]

  alias BeamWeaver.Provider.OpenAICompatibleStreaming
  alias BeamWeaver.Core.Error
  alias BeamWeaver.ZAI.Messages, as: ZAIMessages

  @spec text_deltas(binary() | [map()] | term()) :: [String.t()]
  def text_deltas(body), do: OpenAICompatibleStreaming.text_deltas(body)

  @spec typed_events(binary() | [map()] | term()) :: [BeamWeaver.Stream.Envelope.t()]
  def typed_events(body), do: OpenAICompatibleStreaming.typed_events(body, config())

  # A live stream ends with the complete reply, the message
  # `stream_body_to_message/2` builds, with its reasoning and priced usage,
  # then the `Done` events.
  def typed_events(events, state), do: OpenAICompatibleStreaming.typed_events(events, state, config())

  def finish_typed_events(state, opts) do
    OpenAICompatibleStreaming.finish_typed_events(state, :zai, fn events ->
      with {:ok, message} <- OpenAICompatibleStreaming.events_to_message(events, config(), opts),
           do: {:ok, price_stream_usage(message)}
    end)
  end

  @spec stream_body_to_message(binary(), keyword()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, Error.t()}
  def stream_body_to_message(body, opts \\ [])

  def stream_body_to_message(body, opts) do
    case OpenAICompatibleStreaming.stream_body_to_message(body, config(), opts) do
      {:ok, message} -> {:ok, price_stream_usage(message)}
      other -> other
    end
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
    reasoning_content = reasoning_content(message)
    header_metadata = Keyword.get(opts, :header_metadata, %{})
    decoded_headers = header_metadata[:headers] || %{}
    x_log_id = decoded_headers[:x_log_id]

    events
    |> Enum.reduce(%{model_provider: "zai", provider: :zai, api: :chat_completions}, fn
      %{"data" => data}, acc when is_map(data) ->
        choice = first_choice(data)
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

  defp first_choice(%{"choices" => [choice | _rest]}) when is_map(choice), do: choice
  defp first_choice(_data), do: nil

  defp reasoning_content(message) do
    message.content
    |> List.wrap()
    |> Enum.flat_map(fn
      %{type: :reasoning, reasoning: text} when is_binary(text) -> [text]
      %{"type" => "reasoning", "reasoning" => text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("")
    |> empty_to_nil()
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp config do
    %{
      provider: :zai,
      provider_name: "Z.ai chat-completions",
      usage_metadata: &ZAIMessages.usage_metadata/1,
      stream_metadata: &stream_metadata/3,
      choice_usage: false,
      include_chunk_id: true,
      reasoning_index: 0,
      unknown_delta_key: :zai_delta
    }
  end
end
