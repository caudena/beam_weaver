defmodule BeamWeaver.Provider.ResponseDecoder do
  @moduledoc false

  alias BeamWeaver.Transport.Response

  def json(result, opts \\ [])

  def json({:ok, %Response{status: status, body: body} = response}, opts)
      when status in 200..299 do
    with {:ok, decoded} <- decode_json_body(body, opts) do
      {:ok, maybe_attach_response_headers(decoded, response, opts)}
    end
  end

  def json({:ok, %Response{} = response}, opts), do: {:error, http_error(response, opts)}
  def json({:error, error}, opts), do: {:error, transport_error(error, opts)}

  def decode_json_body(body, opts \\ [])
  def decode_json_body(body, _opts) when is_map(body), do: {:ok, body}

  def decode_json_body(body, opts) when is_binary(body) do
    case BeamWeaver.JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, decoded} ->
        {:error,
         new_error(
           opts,
           :invalid_response,
           "#{provider_name(opts)} JSON response must be an object",
           %{
             decoded: inspect(decoded)
           }
         )}

      {:error, error} ->
        {:error,
         new_error(
           opts,
           :invalid_response,
           "#{provider_name(opts)} response body was not valid JSON",
           %{
             reason: Exception.message(error)
           }
         )}
    end
  end

  def decode_json_body(body, opts) do
    {:error,
     new_error(
       opts,
       :invalid_response,
       "#{provider_name(opts)} response body was not JSON-compatible",
       %{
         body: inspect(body)
       }
     )}
  end

  def http_error(%Response{} = response, opts \\ []) do
    body = decode_error_body(response.body)
    provider_error = if is_map(body), do: body["error"] || body[:error], else: nil

    message =
      error_message(provider_error) ||
        "#{provider_name(opts)} request failed with HTTP #{response.status}"

    new_error(opts, error_type(response.status, provider_error, message, opts), message, %{
      status: response.status,
      body: BeamWeaver.Transport.Redactor.redact(response.body),
      error: provider_error,
      error_type: error_field(provider_error, "type"),
      code: error_field(provider_error, "code"),
      param: error_field(provider_error, "param"),
      request_id: response_header(response, Keyword.get(opts, :request_id_header, "x-request-id")),
      retryable: response.status in [408, 409, 425, 429, 500, 502, 503, 504]
    })
  end

  def transport_error(error, opts \\ []) do
    new_error(opts, :transport_error, "#{provider_name(opts)} transport request failed", %{
      reason: inspect(error)
    })
  end

  defp error_type(status, provider_error, message, opts) do
    context_overflow? = Keyword.get(opts, :context_overflow?, &default_context_overflow?/3)

    if context_overflow?.(status, provider_error, message) do
      :context_overflow
    else
      :http_error
    end
  end

  defp default_context_overflow?(400, provider_error, message) do
    error_field(provider_error, "code") in ["context_length_exceeded", "prompt_too_long"] or
      context_overflow_message?(message)
  end

  defp default_context_overflow?(_status, _provider_error, _message), do: false

  defp context_overflow_message?(message) when is_binary(message) do
    normalized = String.downcase(message)

    String.contains?(normalized, "context window") or
      String.contains?(normalized, "context length") or
      String.contains?(normalized, "prompt is too long") or
      String.contains?(normalized, "input tokens exceed") or
      String.contains?(normalized, "too many tokens")
  end

  defp context_overflow_message?(_message), do: false

  defp maybe_attach_response_headers(decoded, %Response{} = response, opts) do
    if Keyword.get(opts, :include_response_headers, false) do
      Map.put(decoded, "_beamweaver_response_headers", Map.new(response.headers))
    else
      decoded
    end
  end

  defp decode_error_body(body) when is_binary(body) do
    case BeamWeaver.JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _error} -> body
    end
  end

  defp decode_error_body(body), do: body

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_error), do: nil

  defp error_field(%{} = error, field),
    do: BeamWeaver.MapAccess.get(error, field)

  defp error_field(_error, _field), do: nil

  defp response_header(%Response{headers: headers}, name) do
    headers
    |> Map.new(fn {key, value} -> {String.downcase(to_string(key)), value} end)
    |> Map.get(String.downcase(name))
  rescue
    _error -> nil
  end

  defp provider_name(opts) do
    case Keyword.fetch(opts, :provider_name) do
      {:ok, name} -> to_string(name)
      :error -> opts |> Keyword.get(:provider, "Provider") |> to_string() |> String.capitalize()
    end
  end

  defp new_error(opts, type, message, details) do
    module = Keyword.get(opts, :error_module, BeamWeaver.Core.Error)

    if function_exported?(module, :new, 3) do
      module.new(type, message, details)
    else
      BeamWeaver.Core.Error.new(type, message, details)
    end
  end
end
