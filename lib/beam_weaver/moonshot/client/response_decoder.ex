defmodule BeamWeaver.Moonshot.Client.ResponseDecoder do
  @moduledoc false

  alias BeamWeaver.Moonshot.Streaming
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Response

  @header_fields [
    msh_context_cache_token_saved: "msh-context-cache-token-saved",
    msh_usage_cache_write_tokens_5m: "msh-usage-cache-write-tokens-5m",
    msh_usage_cache_write_tokens_1h: "msh-usage-cache-write-tokens-1h",
    msh_gid: "msh-gid",
    msh_org_id: "msh-org-id",
    msh_project_id: "msh-project-id",
    msh_request_id: "msh-request-id",
    msh_trace_mode: "msh-trace-mode",
    msh_uid: "msh-uid",
    x_msh_trace_id: "x-msh-trace-id"
  ]

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
    do: ResponseDecoder.header_metadata(headers, @header_fields, request_id: :msh_request_id)

  defp decoder_opts(opts \\ []) do
    [
      provider: :moonshot,
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      context_overflow?: &context_overflow?/3,
      classify: &classify/1
    ]
  end

  # Kimi names the error in `type`, such as `exceeded_current_quota_error`
  # (HTTP 429 or 403, an exhausted balance or suspended account), which
  # retrying can't fix, or `engine_overloaded_error` (HTTP 429), which it can.
  defp classify(%{type: :http_error, details: details} = error) do
    status = details[:status]
    code = ResponseDecoder.error_field(details[:error], "code") || details[:code]
    error_type = ResponseDecoder.error_field(details[:error], "type") || details[:error_type]

    type =
      cond do
        status == 401 -> :authentication_error
        "exceeded_current_quota_error" in [code, error_type] -> :quota_error
        "engine_overloaded_error" in [code, error_type] or status in [502, 503, 504] -> :overloaded_error
        status == 429 -> :rate_limit_error
        error_type == "content_filter" or code == "content_filter" -> :content_filter
        true -> :http_error
      end

    details = if type == :quota_error, do: Map.put(details, :retryable, false), else: details
    %{error | type: type, details: details}
  end

  defp classify(error), do: error

  defp context_overflow?(400, provider_error, message) when is_binary(message) do
    code = ResponseDecoder.error_field(provider_error, "code")
    normalized = String.downcase(message)

    code in ["context_length_exceeded", "prompt_too_long"] or
      String.contains?(normalized, "input token length too long") or
      String.contains?(normalized, "exceeded model token limit") or
      String.contains?(normalized, "exceeds the model specification") or
      String.contains?(normalized, "context length") or
      String.contains?(normalized, "too many tokens")
  end

  defp context_overflow?(_status, _provider_error, _message), do: false
end
