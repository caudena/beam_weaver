defmodule BeamWeaver.Provider.ResponseDecoder do
  @moduledoc false

  alias BeamWeaver.MapShape
  alias BeamWeaver.Provider.StreamFailure
  alias BeamWeaver.Transport.Response

  @header_metadata_key "_beamweaver_response_header_metadata"

  @doc """
  Calls `on_success` with a 2xx response. Other statuses become the provider's
  classified HTTP error and transport failures become a transport error.
  """
  @spec decode({:ok, Response.t()} | {:error, term()}, keyword(), (Response.t() -> result)) ::
          result | {:error, BeamWeaver.Core.Error.t()}
        when result: term()
  def decode({:ok, %Response{status: status} = response}, _opts, on_success) when status in 200..299,
    do: on_success.(response)

  def decode({:ok, %Response{} = response}, opts, _on_success), do: {:error, http_error(response, opts)}
  def decode({:error, error}, opts, _on_success), do: {:error, transport_error(error, opts)}

  def json(result, opts \\ [])

  # A reply that the provider ends with a finish reason that reports a
  # failure fails as it does in a stream (see `StreamFailure`).
  def json({:ok, %Response{status: status, body: body} = response}, opts)
      when status in 200..299 do
    with {:ok, decoded} <- decode_json_body(body, opts) do
      case StreamFailure.response_failure(decoded) do
        nil -> {:ok, maybe_attach_response_headers(decoded, response, opts)}
        {status, failed} -> {:error, http_error(%{response | status: status, body: failed}, opts)}
      end
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

    type = error_type(response.status, provider_error, message, opts)
    classify = Keyword.get(opts, :classify, & &1)

    opts
    |> new_error(type, message, %{
      status: response.status,
      body: BeamWeaver.Transport.Redactor.redact(response.body),
      error: provider_error,
      error_type: error_field(provider_error, "type"),
      code: error_field(provider_error, "code"),
      param: error_field(provider_error, "param"),
      request_id: response_header(response, Keyword.get(opts, :request_id_header, "x-request-id")),
      retryable: type != :billing_exhausted and BeamWeaver.RetryPredicates.transient_status?(response.status)
    })
    |> classify.()
  end

  @doc """
  Turns a failed transport call into a `:transport_error`.

  A `BeamWeaver.Transport.Error` keeps its type as `details.reason` (such as
  `:cassette_mismatch` or `:timeout`) and its details, with secrets redacted.
  A `BeamWeaver.Core.Error`, such as a missing API key found before the
  request was sent, is returned unchanged.
  """
  def transport_error(error, opts \\ [])

  def transport_error(%BeamWeaver.Core.Error{} = error, _opts), do: error

  def transport_error(%BeamWeaver.Transport.Error{} = error, opts) do
    details =
      error.details
      |> Map.new()
      |> BeamWeaver.Transport.Redactor.redact()
      |> rename_key(:reason, :cause)
      |> Map.merge(%{reason: error.type, retryable: BeamWeaver.RetryPredicates.transient?(error)})

    new_error(opts, :transport_error, "#{provider_name(opts)} transport request failed: #{error.message}", details)
  end

  def transport_error(error, opts) do
    new_error(opts, :transport_error, "#{provider_name(opts)} transport request failed", %{
      reason: inspect(error)
    })
  end

  defp rename_key(map, from, to) do
    case Map.pop(map, from) do
      {nil, map} -> map
      {value, map} -> Map.put(map, to, value)
    end
  end

  defp error_type(status, provider_error, message, opts) do
    context_overflow? = Keyword.get(opts, :context_overflow?, &default_context_overflow?/3)

    cond do
      context_overflow?.(status, provider_error, message) -> :context_overflow
      billing_exhausted?(status, provider_error, message) -> :billing_exhausted
      true -> :http_error
    end
  end

  # OpenAI's spend and usage limits last until someone raises them or the
  # month ends, so retrying can't fix them either.
  defp billing_exhausted?(status, error, message) when status in [402, 403, 429] do
    code = error_field(error, "code")

    code in [
      "insufficient_quota",
      "billing_hard_limit_reached",
      "credit_balance_too_low",
      "credit_balance_exhausted",
      "organization_spend_limit_exceeded",
      "project_spend_limit_exceeded",
      "organization_usage_limit_exceeded"
    ] or
      String.contains?(String.downcase(message), [
        "prepayment credits are depleted",
        "credit balance is too low",
        "insufficient credits"
      ])
  end

  defp billing_exhausted?(_status, _error, _message), do: false

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

  @doc false
  def error_field(%{} = error, field), do: BeamWeaver.MapAccess.get(error, field)
  def error_field(_error, _field), do: nil

  @doc """
  Picks provider response headers into metadata.

  `fields` maps metadata keys to (lowercase) header names; `summary` copies
  selected header values to the top level, such as `request_id`.
  """
  @spec header_metadata([{String.t(), String.t()}] | term(), keyword(String.t()), keyword(atom())) :: map()
  def header_metadata(headers, fields, summary \\ [request_id: :request_id]) do
    headers =
      if is_list(headers), do: Map.new(headers, fn {name, value} -> {String.downcase(name), value} end), else: %{}

    picked = fields |> Map.new(fn {key, name} -> {key, headers[name]} end) |> compact_headers()

    summary
    |> Map.new(fn {key, header_key} -> {key, picked[header_key]} end)
    |> Map.put(:headers, picked)
    |> compact_headers()
  end

  @doc "Stores response header metadata on a decoded provider body for message decoding."
  @spec attach_header_metadata(map(), map()) :: map()
  def attach_header_metadata(decoded, metadata) when map_size(metadata) == 0, do: decoded
  def attach_header_metadata(decoded, metadata), do: Map.put(decoded, @header_metadata_key, metadata)

  defp compact_headers(map), do: MapShape.compact(map, [nil, :empty_string, :empty_map])

  defp response_header(%Response{headers: headers}, name) do
    headers
    |> Map.new(fn {key, value} -> {String.downcase(to_string(key)), value} end)
    |> Map.get(String.downcase(name))
  end

  defp provider_name(opts) do
    case Keyword.fetch(opts, :provider_name) do
      {:ok, name} -> to_string(name)
      :error -> opts |> Keyword.get(:provider, "Provider") |> to_string() |> String.capitalize()
    end
  end

  defp new_error(_opts, type, message, details), do: BeamWeaver.Core.Error.new(type, message, details)

  @doc false
  # The `transport` metadata a message carries: the provider request id.
  def transport_metadata(%{request_id: request_id}) when is_binary(request_id) and request_id != "",
    do: %{request_id: request_id}

  def transport_metadata(_header_metadata), do: nil
end
