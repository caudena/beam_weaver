defmodule BeamWeaver.ZAI.Client.ResponseDecoder do
  @moduledoc false

  alias BeamWeaver.Core.Error, as: CoreError
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Response
  alias BeamWeaver.ZAI.Error
  alias BeamWeaver.ZAI.Streaming

  def json(result, opts) do
    result
    |> ResponseDecoder.json(decoder_opts(opts))
    |> normalize_error()
  end

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

  def stream_message({:ok, %Response{status: status, body: body, headers: headers}}, _opts)
      when status in 200..299 do
    Streaming.stream_body_to_message(body, headers: headers)
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
    error_type = error_field(provider_error, "type") || details[:error_type] || details["error_type"]

    type =
      cond do
        status == 401 -> :authentication_error
        status == 429 -> :rate_limit_error
        status in [502, 503, 504] -> :overloaded_error
        code in ["insufficient_quota", "quota_exceeded"] -> :quota_error
        error_type == "content_filter" or code == "content_filter" -> :content_filter
        true -> :http_error
      end

    %{error | type: type}
  end

  defp normalize_error_value(error), do: error

  defp decoder_opts(opts \\ []) do
    [
      provider: :zai,
      provider_name: "Z.ai",
      error_module: Error,
      include_response_headers: true,
      context_overflow?: &context_overflow?/3,
      request_id_header: "x-log-id"
    ]
    |> Keyword.merge(Keyword.take(opts, [:include_response_headers]))
    |> Keyword.put(:include_response_headers, true)
  end

  defp context_overflow?(400, provider_error, message) when is_binary(message) do
    code = error_field(provider_error, "code")
    normalized = String.downcase(message)

    code in ["context_length_exceeded", "prompt_too_long"] or
      String.contains?(normalized, "context length") or
      String.contains?(normalized, "token limit") or
      String.contains?(normalized, "too many tokens")
  end

  defp context_overflow?(_status, _provider_error, _message), do: false

  defp error_field(%{} = error, field),
    do: BeamWeaver.MapAccess.get(error, field)

  defp error_field(_error, _field), do: nil
end
