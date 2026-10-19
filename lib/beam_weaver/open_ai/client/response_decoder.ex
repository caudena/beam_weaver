defmodule BeamWeaver.OpenAI.Client.ResponseDecoder do
  @moduledoc false

  # Decodes OpenAI-shaped HTTP responses. Other OpenAI-compatible providers
  # reuse these functions with their own `config/0`-shaped map.

  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.Streaming
  alias BeamWeaver.Provider.OpenAICompatibleStreaming
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Response

  @header_fields [
    request_id: "x-request-id",
    openai_organization: "openai-organization",
    openai_processing_ms: "openai-processing-ms",
    openai_project: "openai-project",
    openai_version: "openai-version",
    x_ratelimit_limit_requests: "x-ratelimit-limit-requests",
    x_ratelimit_limit_tokens: "x-ratelimit-limit-tokens",
    x_ratelimit_remaining_requests: "x-ratelimit-remaining-requests",
    x_ratelimit_remaining_tokens: "x-ratelimit-remaining-tokens",
    x_ratelimit_reset_requests: "x-ratelimit-reset-requests",
    x_ratelimit_reset_tokens: "x-ratelimit-reset-tokens"
  ]

  @doc false
  def config, do: %{provider: :openai, provider_name: "OpenAI", header_fields: @header_fields}

  def json(result, opts, config), do: ResponseDecoder.json(result, decoder_opts(config, opts))

  def stream_error({:ok, %Response{} = response}, config),
    do: {:error, ResponseDecoder.http_error(response, decoder_opts(config))}

  def stream_error({:error, error}, config), do: {:error, ResponseDecoder.transport_error(error, decoder_opts(config))}

  def responses_stream_map(result, opts, config) do
    ResponseDecoder.decode(result, decoder_opts(config), fn response ->
      {:ok,
       response.body |> Streaming.response() |> ResponseDecoder.attach_headers(response, decoder_opts(config, opts))}
    end)
  end

  # A collected stream decodes to the Chat Completions response its events add
  # up to, so it becomes the same message as a non-streamed response.
  def chat_completions_stream_response(result, opts, config) do
    ResponseDecoder.decode(result, decoder_opts(config), fn response ->
      case response.body |> Streaming.events() |> OpenAICompatibleStreaming.chat_completion() do
        %{"choices" => []} ->
          {:error, Error.new(:invalid_response, "#{config.provider_name} chat-completions stream had no choices")}

        completion ->
          {:ok, ResponseDecoder.attach_headers(completion, response, decoder_opts(config, opts))}
      end
    end)
  end

  # Ends a live Chat Completions stream with the complete reply: the response
  # the stream's events add up to, decoded by `decode` like a non-streamed one.
  def finish_chat_completions_typed_events(state, %Response{} = response, opts, config, decode) do
    OpenAICompatibleStreaming.finish_typed_events(state, config.provider, fn events ->
      case OpenAICompatibleStreaming.chat_completion(events) do
        %{"choices" => []} -> :none
        completion -> completion |> ResponseDecoder.attach_headers(response, decoder_opts(config, opts)) |> decode.()
      end
    end)
  end

  def chat_message(result, opts, config) do
    ResponseDecoder.decode(result, decoder_opts(config), fn response ->
      OpenAICompatibleStreaming.stream_body_to_message(
        response.body,
        config.stream,
        message_opts(response, opts, config)
      )
    end)
  end

  # Ends a live typed stream with the complete reply, which carries the
  # response's header metadata like a reply from `chat_message/3`.
  def finish_chat_message_events(state, %Response{} = response, opts, config) do
    message_opts = message_opts(response, opts, config)

    OpenAICompatibleStreaming.finish_typed_events(
      state,
      config.provider,
      &OpenAICompatibleStreaming.events_to_message(&1, config.stream, message_opts)
    )
  end

  defp message_opts(%Response{} = response, opts, config) do
    [
      header_metadata: ResponseDecoder.header_metadata(response.headers, config.header_fields, config.header_summary),
      raw_response_headers: response.headers,
      include_response_headers: Keyword.get(opts, :include_response_headers, false)
    ]
  end

  defp decoder_opts(config, opts \\ []) do
    config
    |> Map.delete(:stream)
    |> Enum.to_list()
    |> Keyword.put(:include_response_headers, Keyword.get(opts, :include_response_headers, false))
  end
end
