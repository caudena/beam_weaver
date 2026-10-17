defmodule BeamWeaver.OpenAI.Client.ResponseDecoder do
  @moduledoc false

  # Decodes OpenAI-shaped HTTP responses. Other OpenAI-compatible providers
  # reuse these functions with their own `config/0`-shaped map.

  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.ChatCompletions
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
  def config do
    %{
      provider: :openai,
      provider_name: "OpenAI",
      header_fields: @header_fields,
      context_overflow?: &context_overflow?/3
    }
  end

  def json(result, opts, config \\ config()) do
    with {:ok, decoded} <- ResponseDecoder.json(result, decoder_opts(config, opts)) do
      {:ok, attach_header_metadata(decoded, result, config)}
    end
  end

  def text_stream(result, config \\ config()),
    do: ResponseDecoder.decode(result, decoder_opts(config), &{:ok, Streaming.text_deltas(&1.body)})

  def responses_stream_map(result, opts, config \\ config()) do
    ResponseDecoder.decode(result, decoder_opts(config), fn response ->
      {:ok, response.body |> Streaming.response() |> maybe_attach_response_headers(response, opts, config)}
    end)
  end

  def lifecycle_events(result, config \\ config()),
    do: ResponseDecoder.decode(result, decoder_opts(config), &{:ok, Streaming.lifecycle_events(&1.body)})

  def typed_events(result, config \\ config()),
    do: ResponseDecoder.decode(result, decoder_opts(config), &{:ok, Streaming.typed_events(&1.body)})

  # A collected stream decodes to the Chat Completions response its events add
  # up to, so it becomes the same message as a non-streamed response.
  def chat_completions_stream_response(result, opts, config \\ config()) do
    ResponseDecoder.decode(result, decoder_opts(config), fn response ->
      case response.body |> Streaming.events() |> OpenAICompatibleStreaming.chat_completion() do
        %{"choices" => []} ->
          {:error, Error.new(:invalid_response, "#{config.provider_name} chat-completions stream had no choices")}

        completion ->
          {:ok, maybe_attach_response_headers(completion, response, opts, config)}
      end
    end)
  end

  # Ends a live Chat Completions stream with the complete reply: the response
  # the stream's events add up to, decoded by `decode` like a non-streamed one.
  def finish_chat_completions_typed_events(
        state,
        %Response{} = response,
        opts,
        config \\ config(),
        decode \\ &ChatCompletions.Messages.response_to_message/1
      ) do
    OpenAICompatibleStreaming.finish_typed_events(state, config.provider, fn events ->
      case OpenAICompatibleStreaming.chat_completion(events) do
        %{"choices" => []} -> :none
        completion -> completion |> maybe_attach_response_headers(response, opts, config) |> decode.()
      end
    end)
  end

  defp decoder_opts(config, opts \\ []) do
    [
      provider: config.provider,
      provider_name: config.provider_name,
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      context_overflow?: config.context_overflow?,
      error_type: Map.get(config, :error_type)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp attach_header_metadata(decoded, {:ok, %Response{headers: headers}}, config) when is_map(decoded),
    do: ResponseDecoder.attach_header_metadata(decoded, header_metadata(headers, config))

  defp attach_header_metadata(decoded, _result, _config), do: decoded

  defp maybe_attach_response_headers(decoded, %Response{} = response, opts, config) do
    decoded = attach_header_metadata(decoded, {:ok, response}, config)

    if Keyword.get(opts, :include_response_headers, false),
      do: Map.put(decoded, "_beamweaver_response_headers", Map.new(response.headers)),
      else: decoded
  end

  defp header_metadata(headers, config), do: ResponseDecoder.header_metadata(headers, config.header_fields)

  defp context_overflow?(status, provider_error, message) do
    status == 400 and
      (ResponseDecoder.error_field(provider_error, "code") == "context_length_exceeded" or
         context_overflow_message?(message))
  end

  defp context_overflow_message?(message) when is_binary(message) do
    String.contains?(String.downcase(message), [
      "context window",
      "context length",
      "prompt is too long",
      "input tokens exceed",
      "too many tokens"
    ])
  end

  defp context_overflow_message?(_message), do: false
end
