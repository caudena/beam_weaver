defmodule BeamWeaver.ZAI.Client.ResponseDecoder do
  @moduledoc false

  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Response
  alias BeamWeaver.ZAI.Streaming

  @header_fields [x_log_id: "x-log-id"]

  def json(result, opts) do
    with {:ok, decoded} <- ResponseDecoder.json(result, decoder_opts(opts)) do
      {:ok, attach_header_metadata(decoded, result)}
    end
  end

  def text_stream(result),
    do: ResponseDecoder.decode(result, decoder_opts(), &{:ok, Streaming.text_deltas(&1.body)})

  def stream_message(result, opts) do
    ResponseDecoder.decode(result, decoder_opts(), fn %Response{} = response ->
      Streaming.stream_body_to_message(response.body, message_opts(response, opts))
    end)
  end

  def typed_events(result),
    do: ResponseDecoder.decode(result, decoder_opts(), &{:ok, Streaming.typed_events(&1.body)})

  # Ends a live typed stream with the complete reply, which carries the
  # response's header metadata like a reply from `stream_message/2`.
  def finish_typed_events(state, %Response{} = response, opts),
    do: Streaming.finish_typed_events(state, message_opts(response, opts))

  defp message_opts(%Response{} = response, opts) do
    [
      header_metadata: header_metadata(response.headers),
      raw_response_headers: response.headers,
      include_response_headers: Keyword.get(opts, :include_response_headers, false)
    ]
  end

  defp attach_header_metadata(decoded, {:ok, %Response{headers: headers}}) when is_map(decoded),
    do: ResponseDecoder.attach_header_metadata(decoded, header_metadata(headers))

  defp attach_header_metadata(decoded, _result), do: decoded

  defp header_metadata(headers),
    do: ResponseDecoder.header_metadata(headers, @header_fields, request_id: :x_log_id)

  defp decoder_opts(opts \\ []) do
    [
      provider: :zai,
      provider_name: "Z.ai",
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      context_overflow?: &context_overflow?/3,
      classify: &classify/1,
      request_id_header: "x-log-id"
    ]
  end

  # Z.ai names each error by a business code (`"1301"`): 1301 is its content
  # filter, 1302 a rate limit and 1305 an overload. 1113 (no balance) and the
  # plan and usage limits, 1308 to 1321, last until the account is recharged
  # or the limit resets hours or days later, so retrying can't fix them. A
  # reply its content filter stops partway ends with the finish reason
  # `sensitive` instead of 1301 (see `StreamFailure`).
  @quota_codes ~w(1113 1308 1309 1310 1311 1313 1314 1315 1316 1317 1318 1319 1320 1321)

  defp classify(%{type: :http_error, details: details} = error) do
    status = details[:status]
    code = error_code(details[:error]) || error_code(details)
    error_type = ResponseDecoder.error_field(details[:error], "type") || details[:error_type]

    type =
      cond do
        quota_error?(status, code, error_type, error.message) -> :quota_error
        status == 401 -> :authentication_error
        code == "1305" or status in [502, 503, 504] -> :overloaded_error
        status == 429 -> :rate_limit_error
        "content_filter" in [code, error_type] or code in ["1301", "sensitive"] -> :content_filter
        true -> :http_error
      end

    details = if type == :quota_error, do: Map.put(details, :retryable, false), else: details
    %{error | type: type, details: details}
  end

  defp classify(error), do: error

  defp quota_error?(429, code, error_type, message) do
    code in ["insufficient_quota", "quota_exceeded" | @quota_codes] or
      error_type in ["insufficient_quota", "quota_exceeded"] or
      (is_binary(message) and
         String.contains?(String.downcase(message), [
           "insufficient balance",
           "no resource package",
           "please recharge",
           "quota exceeded"
         ]))
  end

  defp quota_error?(_status, _code, _error_type, _message), do: false

  # 1261 is "Prompt too long".
  defp context_overflow?(400, provider_error, message) when is_binary(message) do
    normalized = String.downcase(message)

    error_code(provider_error) in ["1261", "context_length_exceeded", "prompt_too_long"] or
      String.contains?(normalized, "context length") or
      String.contains?(normalized, "token limit") or
      String.contains?(normalized, "too many tokens")
  end

  defp context_overflow?(_status, _provider_error, _message), do: false

  # Z.ai's error reference gives its codes as numbers, its responses as
  # strings.
  defp error_code(error) do
    case ResponseDecoder.error_field(error, "code") do
      code when is_integer(code) -> Integer.to_string(code)
      code -> code
    end
  end
end
