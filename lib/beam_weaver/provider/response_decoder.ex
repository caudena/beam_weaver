defmodule BeamWeaver.Provider.ResponseDecoder do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapShape
  alias BeamWeaver.Provider.StreamFailure
  alias BeamWeaver.Transport.Response

  @header_metadata_key "_beamweaver_response_header_metadata"

  @doc """
  Calls `on_success` with a 2xx response. Other statuses and transport
  failures become an error (see `http_error/2` and `transport_error/2`).
  """
  @spec decode({:ok, Response.t()} | {:error, term()}, keyword(), (Response.t() -> result)) ::
          result | {:error, Error.t()}
        when result: term()
  def decode({:ok, %Response{status: status} = response}, _opts, on_success) when status in 200..299,
    do: on_success.(response)

  def decode({:ok, %Response{} = response}, opts, _on_success), do: {:error, http_error(response, opts)}
  def decode({:error, error}, opts, _on_success), do: {:error, transport_error(error, opts)}

  # A reply that the provider ends with a finish reason that reports a
  # failure fails as it does in a stream (see `StreamFailure`).
  def json(result, opts) do
    decode(result, opts, fn response ->
      with {:ok, decoded} <- decode_json_body(response.body, opts) do
        case StreamFailure.response_failure(decoded) do
          nil -> {:ok, attach_headers(decoded, response, opts)}
          {status, failed} -> {:error, http_error(%{response | status: status, body: failed}, opts)}
        end
      end
    end)
  end

  defp decode_json_body(body, _opts) when is_map(body), do: {:ok, body}

  defp decode_json_body(body, opts) when is_binary(body) do
    case BeamWeaver.JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, decoded} ->
        {:error,
         Error.new(:invalid_response, "#{provider_name(opts)} JSON response must be an object", %{
           decoded: inspect(decoded)
         })}

      {:error, error} ->
        {:error,
         Error.new(:invalid_response, "#{provider_name(opts)} response body was not valid JSON", %{
           reason: Exception.message(error)
         })}
    end
  end

  defp decode_json_body(body, opts) do
    {:error,
     Error.new(:invalid_response, "#{provider_name(opts)} response body was not JSON-compatible", %{body: inspect(body)})}
  end

  def http_error(%Response{} = response, opts) do
    provider_error = response.body |> decode_error_body() |> provider_error()

    message =
      error_message(provider_error) ||
        "#{provider_name(opts)} request failed with HTTP #{response.status}"

    type = error_type(response.status, provider_error, message, opts)

    Error.new(type, message, %{
      status: response.status,
      body: BeamWeaver.Transport.Redactor.redact(response.body),
      error: provider_error,
      error_type: error_field(provider_error, "type"),
      code: error_field(provider_error, "code"),
      param: error_field(provider_error, "param"),
      request_id: response_header(response, Keyword.get(opts, :request_id_header, "x-request-id")),
      retryable: retryable?(type, response.status)
    })
  end

  @doc """
  Turns a failed transport call into an error: a `:timeout`, a `:connection`
  error when the request got no response, or a `:transport_error` when the
  transport refused it, such as a URL its policy blocks or a cassette
  mismatch.

  A `BeamWeaver.Transport.Error` keeps its type as `details.reason` (such as
  `:cassette_mismatch` or `:timeout`) and its details, with secrets redacted.
  A `BeamWeaver.Core.Error`, such as a missing API key found before the
  request was sent, is returned unchanged.
  """
  def transport_error(%Error{} = error, _opts), do: error

  def transport_error(%BeamWeaver.Transport.Error{} = error, opts) do
    type = transport_type(error.type)

    details =
      error.details
      |> Map.new()
      |> BeamWeaver.Transport.Redactor.redact()
      |> rename_key(:reason, :cause)
      |> Map.merge(%{
        reason: error.type,
        retryable: type in [:timeout, :connection] or BeamWeaver.RetryPredicates.transient?(error)
      })

    Error.new(type, "#{provider_name(opts)} transport request failed: #{error.message}", details)
  end

  def transport_error(error, opts),
    do: Error.new(:transport_error, "#{provider_name(opts)} transport request failed", %{reason: inspect(error)})

  defp rename_key(map, from, to) do
    case Map.pop(map, from) do
      {nil, map} -> map
      {value, map} -> Map.put(map, to, value)
    end
  end

  defp transport_type(:timeout), do: :timeout
  defp transport_type(type) when type in [:transport_failure, :closed], do: :connection
  defp transport_type(_type), do: :transport_error

  # An error's type follows its HTTP status, the same for every provider,
  # unless the error says more: that the prompt is over the context window
  # (`:context_overflow?` checks the provider's wording), that credits or a
  # usage limit ran out, or, from the provider's `:error_type`, a code of its
  # own such as a content filter.
  @status_types %{
    400 => :invalid_request,
    401 => :authentication,
    402 => :billing_exhausted,
    403 => :permission_denied,
    404 => :not_found,
    422 => :invalid_request,
    429 => :rate_limit
  }

  defp error_type(status, provider_error, message, opts) do
    context_overflow? = Keyword.get(opts, :context_overflow?, &default_context_overflow?/3)
    provider_type = Keyword.get(opts, :error_type, fn _status, _provider_error, _message -> nil end)

    cond do
      context_overflow?.(status, provider_error, message) -> :context_overflow
      billing_exhausted?(status, provider_error, message) -> :billing_exhausted
      true -> provider_type.(status, provider_error, message) || status_type(status)
    end
  end

  defp status_type(status) when status in 500..599, do: :server_error
  defp status_type(status), do: Map.get(@status_types, status, :http_error)

  # Retrying can fix a rate limit, a server error, and the other statuses
  # that say so (a request timeout, a conflict, a request sent too early).
  defp retryable?(type, _status) when type in [:rate_limit, :server_error], do: true
  defp retryable?(:http_error, status), do: BeamWeaver.RetryPredicates.transient_status?(status)
  defp retryable?(_type, _status), do: false

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

  # Some OpenAI-compatible servers answer an overflow with a 413 or 422, which
  # other errors share, so those count only when the error says overflow.
  defp default_context_overflow?(status, provider_error, message) when status in [400, 413, 422] do
    error_field(provider_error, "code") in ["context_length_exceeded", "prompt_too_long"] or
      context_overflow_message?(message)
  end

  defp default_context_overflow?(_status, _provider_error, _message), do: false

  @doc false
  # Whether an error message says the prompt is over the context window, in
  # the words of OpenAI, Anthropic, or an OpenAI-compatible server such as
  # llama.cpp, LiteLLM or Text Generation Inference.
  def context_overflow_message?(message) when is_binary(message) do
    String.contains?(String.downcase(message), [
      "context window",
      "context length",
      "maximum context",
      "exceeds the available context size",
      "context limit exceeded",
      "contextwindowexceedederror",
      "prompt is too long",
      "input tokens exceed",
      "too many tokens",
      "`inputs` tokens + `max_new_tokens` must be",
      "`inputs` must have less than"
    ])
  end

  def context_overflow_message?(_message), do: false

  def attach_headers(decoded, %Response{} = response, opts) do
    fields = Keyword.get(opts, :header_fields, [])
    summary = Keyword.get(opts, :header_summary, request_id: :request_id)
    decoded = attach_header_metadata(decoded, header_metadata(response.headers, fields, summary))

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

  # Most APIs nest the error in an `error` object; xAI's is the body itself,
  # with the message in `error`.
  defp provider_error(%{"error" => message} = body) when is_binary(message),
    do: body |> Map.take(["code", "type"]) |> Map.put("message", message)

  defp provider_error(%{} = body), do: body["error"] || body[:error]
  defp provider_error(_body), do: nil

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

  # Stores response header metadata on a decoded provider body for message decoding.
  defp attach_header_metadata(decoded, metadata) when map_size(metadata) == 0, do: decoded
  defp attach_header_metadata(decoded, metadata), do: Map.put(decoded, @header_metadata_key, metadata)

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

  @doc false
  # The `transport` metadata a message carries: the provider request id.
  def transport_metadata(%{request_id: request_id}) when is_binary(request_id) and request_id != "",
    do: %{request_id: request_id}

  def transport_metadata(_header_metadata), do: nil
end
