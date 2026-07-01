defmodule BeamWeaver.Moonshot.Client.ResponseDecoder do
  @moduledoc false

  alias BeamWeaver.Core.Error, as: CoreError
  alias BeamWeaver.Moonshot.Error
  alias BeamWeaver.Moonshot.Streaming
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Response

  def json({:ok, %Response{} = response} = result, opts) do
    result
    |> ResponseDecoder.json(decoder_opts(opts))
    |> attach_result_header_metadata(response.headers)
    |> normalize_error()
  end

  def json(result, opts),
    do: result |> ResponseDecoder.json(decoder_opts(opts)) |> normalize_error()

  def text_stream({:ok, %Response{status: status, body: body}})
      when status in 200..299 do
    {:ok, Streaming.text_deltas(body)}
  end

  def text_stream({:ok, %Response{} = response}) do
    {:error, normalize_http_error(response)}
  end

  def text_stream({:error, error}) do
    {:error, ResponseDecoder.transport_error(error, decoder_opts())}
  end

  def stream_message({:ok, %Response{status: status, body: body, headers: headers}}, opts)
      when status in 200..299 do
    Streaming.stream_body_to_message(body,
      header_metadata: header_metadata(headers),
      raw_response_headers: headers,
      include_response_headers: Keyword.get(opts, :include_response_headers, false)
    )
  end

  def stream_message({:ok, %Response{} = response}, _opts) do
    {:error, normalize_http_error(response)}
  end

  def stream_message({:error, error}, _opts) do
    {:error, ResponseDecoder.transport_error(error, decoder_opts())}
  end

  def typed_events({:ok, %Response{status: status, body: body}})
      when status in 200..299 do
    {:ok, Streaming.typed_events(body)}
  end

  def typed_events({:ok, %Response{} = response}) do
    {:error, normalize_http_error(response)}
  end

  def typed_events({:error, error}) do
    {:error, ResponseDecoder.transport_error(error, decoder_opts())}
  end

  defp normalize_http_error(response) do
    response
    |> ResponseDecoder.http_error(decoder_opts())
    |> normalize_error_value()
  end

  defp normalize_error({:error, %Error{} = error}), do: {:error, normalize_error_value(error)}
  defp normalize_error({:error, %CoreError{} = error}), do: {:error, normalize_error_value(error)}
  defp normalize_error(other), do: other

  defp normalize_error_value(%{type: :context_overflow} = error), do: error

  defp normalize_error_value(%{type: :http_error, details: details} = error) do
    provider_error = details[:error] || details["error"] || %{}
    status = details[:status] || details["status"]
    code = error_field(provider_error, "code") || details[:code] || details["code"]

    error_type =
      error_field(provider_error, "type") || details[:error_type] || details["error_type"]

    type =
      cond do
        status == 401 -> :authentication_error
        status == 429 and code == "exceeded_current_quota_error" -> :quota_error
        status == 429 -> :rate_limit_error
        code == "engine_overloaded_error" or status in [502, 503, 504] -> :overloaded_error
        error_type == "content_filter" or code == "content_filter" -> :content_filter
        true -> :http_error
      end

    %{error | type: type}
  end

  defp normalize_error_value(error), do: error

  defp attach_result_header_metadata({:ok, decoded}, headers) when is_map(decoded) do
    {:ok, attach_header_metadata(decoded, headers)}
  end

  defp attach_result_header_metadata(result, _headers), do: result

  defp attach_header_metadata(decoded, headers) when is_map(decoded) do
    metadata = header_metadata(headers)

    if map_size(metadata) > 0,
      do: Map.put(decoded, "_beamweaver_response_header_metadata", metadata),
      else: decoded
  end

  defp header_metadata(headers) do
    headers = response_headers(headers)

    decoded =
      %{
        msh_context_cache_token_saved: headers["msh-context-cache-token-saved"],
        msh_gid: headers["msh-gid"],
        msh_org_id: headers["msh-org-id"],
        msh_project_id: headers["msh-project-id"],
        msh_request_id: headers["msh-request-id"],
        msh_trace_mode: headers["msh-trace-mode"],
        msh_uid: headers["msh-uid"],
        x_msh_trace_id: headers["x-msh-trace-id"]
      }
      |> reject_empty_header_values()

    %{headers: decoded, request_id: decoded[:msh_request_id]}
    |> reject_empty_header_values()
  end

  defp response_headers(headers) when is_list(headers) do
    Map.new(headers)
  end

  defp response_headers(_headers), do: %{}

  defp reject_empty_header_values(map) do
    Map.reject(map, fn
      {_key, value} when value in [nil, ""] -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
  end

  defp decoder_opts(opts \\ []) do
    [
      provider: :moonshot,
      error_module: Error,
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      context_overflow?: &context_overflow?/3
    ]
  end

  defp context_overflow?(400, provider_error, message) when is_binary(message) do
    code = error_field(provider_error, "code")
    normalized = String.downcase(message)

    code in ["context_length_exceeded", "prompt_too_long"] or
      String.contains?(normalized, "input token length too long") or
      String.contains?(normalized, "exceeded model token limit") or
      String.contains?(normalized, "context length") or
      String.contains?(normalized, "too many tokens")
  end

  defp context_overflow?(_status, _provider_error, _message), do: false

  defp error_field(%{} = error, field),
    do: BeamWeaver.MapAccess.get(error, field)

  defp error_field(_error, _field), do: nil
end
