defmodule BeamWeaver.Google.Client do
  @moduledoc ~S"""
  Native Google HTTP client using `BeamWeaver.Transport`.

  Use this layer when your application owns provider request/response shapes.
  It accepts native bodies and returns decoded provider data or tagged errors;
  the model facade supplies portable message normalization and compatibility
  checks. Transport/replay overrides do not establish live provider access.

  Configure this client's credentials for its actual endpoint. Keep raw request
  headers/bodies out of logs. Stream consumers own consumption and cancellation;
  collected-response helpers wait for completion. The [Google guide](providers/google.md)
  identifies the implemented endpoints and external-resource lifetimes.

  Gemini 4 Argon follows continuation checkpoints automatically, including on
  `generate_content/4` (which collects streaming HTTP internally). All hops use
  the original request and output budget. Set `automatic_continuation: false`
  for one native request. `max_continuation_retries:` defaults to 2 and bounds
  reconnects after transient stream failures; it does not limit successful hops.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Google.LongDecode
  alias BeamWeaver.Google.Streaming
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Request

  @default_base_url "https://generativelanguage.googleapis.com/v1beta"
  @header_opts [
    header_fields: [x_gemini_service_tier: "x-gemini-service-tier"],
    header_summary: [service_tier: :x_gemini_service_tier]
  ]

  defstruct base_url: @default_base_url,
            api_key: nil,
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  @doc """
  Builds client connection settings from explicit options and provider application configuration; makes no request.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      base_url:
        Keyword.get(opts, :base_url) || Keyword.get(opts, :endpoint) ||
          Config.get([:google, :base_url], @default_base_url),
      api_key: Config.option(opts, :api_key, [:google, :api_key]),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, 15_000)
    }
  end

  @doc """
  Sends a native JSON request and returns the decoded provider payload or a tagged HTTP/transport error.
  """
  @spec generate_content(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def generate_content(%__MODULE__{} = client, model, body, opts \\ []) do
    if LongDecode.enabled?(model, opts) do
      stream_response(client, model, body, opts)
    else
      client
      |> http(model, :generate_content, opts)
      |> HTTPClient.post_json(body, opts)
      |> decode_result(opts)
    end
  end

  @doc """
  Calls the provider counting/estimation endpoint with a native body; returns decoded provider data or an error.
  """
  @spec count_tokens(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def count_tokens(%__MODULE__{} = client, model, body, opts \\ []) do
    client
    |> http(model, :count_tokens, opts)
    |> HTTPClient.post_json(body, opts)
    |> ResponseDecoder.json(decoder_opts(opts))
  end

  @doc """
  Sends a streaming request and returns text deltas. Consume the returned enumerable to execute streaming work.
  """
  @spec stream_text(t(), String.t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_text(%__MODULE__{} = client, model, body, opts \\ []) do
    if LongDecode.enabled?(model, opts) do
      with {:ok, events} <- stream_events(client, model, body, opts) do
        {:ok,
         Stream.flat_map(events, fn
           %BeamWeaver.Stream.Envelope{event: %BeamWeaver.Stream.Events.Token{text: text}} -> [text]
           %BeamWeaver.Stream.Envelope{event: %BeamWeaver.Stream.Events.Error{} = error} -> [error]
           _ -> []
         end)}
      end
    else
      client
      |> http(model, :stream_generate_content, opts)
      |> HTTPClient.stream_sse(body, opts, &Streaming.text_deltas/1, &decode_result(&1, opts))
    end
  end

  @doc """
  Collects the streaming provider response into its final decoded native payload, or returns an error.
  """
  @spec stream_response(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def stream_response(%__MODULE__{} = client, model, body, opts \\ []) do
    if LongDecode.enabled?(model, opts) do
      with {:ok, events} <- stream_events(client, model, body, opts), do: LongDecode.collect(events)
    else
      client
      |> http(model, :stream_generate_content, opts)
      |> HTTPClient.collect_sse(body, opts, &decode_sse_result(&1, opts))
    end
  end

  @doc """
  Sends a streaming request and returns typed event envelopes. Consume once and handle terminal errors.
  """
  @spec stream_events(t(), String.t(), map() | binary(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_events(%__MODULE__{} = client, model, body, opts \\ []) do
    if LongDecode.enabled?(model, opts) do
      LongDecode.stream(&raw_stream(client, model, &1, opts), body, opts)
    else
      single_stream(client, model, body, opts)
    end
  end

  defp raw_stream(client, model, body, opts) do
    http = http(client, model, :stream_generate_content, opts)
    # Continuation tokens grow with the context and repeat in checkpoint
    # frames. Real long decodes can exceed the transport's ordinary 5 MB cap.
    # Match the configured stream bound, preserving explicit transport limits.
    maximum =
      Keyword.get(
        http.transport_opts,
        :max_response_bytes,
        BeamWeaver.Provider.StreamValidator.new(opts).max_transport_bytes
      )

    opts = Keyword.put_new(opts, :max_response_bytes, maximum)

    finalize = fn _state, response ->
      with {:ok, headers} <- decode_result({:ok, %{response | body: %{}}}, opts),
           do: {:ok, LongDecode.raw_end(headers)}
    end

    http
    |> HTTPClient.stream_typed_sse(
      body,
      opts |> Keyword.put(:parser_finalizer, finalize) |> Keyword.put(:strict_sse, true),
      &LongDecode.raw_events/2,
      &decode_result(&1, opts)
    )
  end

  defp single_stream(client, model, body, opts) do
    finalize = fn state, response ->
      Streaming.finish_typed_events(state, &decode_result({:ok, %{response | body: &1}}, opts))
    end

    client
    |> http(model, :stream_generate_content, opts)
    |> HTTPClient.stream_typed_sse(
      body,
      opts |> Keyword.put(:parser_finalizer, finalize) |> Keyword.put(:strict_sse, true),
      &Streaming.typed_events/2,
      &decode_result(&1, opts)
    )
  end

  @doc """
  Builds the normalized transport request for inspection or explicit dispatch; does not send it.
  """
  @spec request(t(), String.t(), atom(), map() | binary(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, model, action, body, opts \\ []),
    do: client |> http(model, action, opts) |> HTTPClient.request(body, opts)

  @doc """
  Builds the native URL for the selected model/action without sending a request.
  """
  def endpoint(%__MODULE__{base_url: base_url}, model, action) do
    base = String.trim_trailing(base_url, "/")
    encoded_model = URI.encode(model, &URI.char_unreserved?/1)

    case action do
      :generate_content -> "#{base}/models/#{encoded_model}:generateContent"
      :stream_generate_content -> "#{base}/models/#{encoded_model}:streamGenerateContent?alt=sse"
      :count_tokens -> "#{base}/models/#{encoded_model}:countTokens"
    end
  end

  # Per-call `:api_key`, `:transport`, `:transport_opts` and `:timeout`
  # override the client's own, as on the other providers.
  defp http(%__MODULE__{} = client, model, action, opts) do
    %HTTPClient{
      provider: :google,
      endpoint: endpoint(client, model, action),
      api_key: Keyword.get(opts, :api_key, client.api_key),
      auth_header: "x-goog-api-key",
      default_headers: [
        {"user-agent", Keyword.get(opts, :user_agent, "beam_weaver-google/0.1")}
        | Request.normalize_headers(client.default_headers)
      ],
      transport: Keyword.get(opts, :transport, client.transport),
      transport_opts: Keyword.get(opts, :transport_opts, client.transport_opts),
      timeout: Keyword.get(opts, :timeout, client.timeout)
    }
  end

  defp decode_result(result, opts), do: ResponseDecoder.json(result, @header_opts ++ decoder_opts(opts))

  defp decode_sse_result(result, opts) do
    ResponseDecoder.decode(result, decoder_opts(opts), fn response ->
      decoded = Streaming.response_from_sse_body(response.body)
      {:ok, ResponseDecoder.attach_headers(decoded, response, @header_opts ++ decoder_opts(opts))}
    end)
  end

  defp decoder_opts(opts) do
    [
      provider: :google,
      request_id_header: "x-request-id",
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      context_overflow?: &context_overflow?/3,
      error_type: &error_type/3
    ]
  end

  # Gemini rejects a wrong or expired API key with a 400 whose `ErrorInfo`
  # reason says so.
  defp error_type(_status, provider_error, _message) do
    reasons = for %{"reason" => reason} <- List.wrap(ResponseDecoder.error_field(provider_error, "details")), do: reason
    if Enum.any?(reasons, &(&1 in ["API_KEY_INVALID", "API_KEY_EXPIRED"])), do: :authentication
  end

  # Gemini says a prompt is too long with a 400 (`INVALID_ARGUMENT`); a 429
  # (`RESOURCE_EXHAUSTED`) whose message names a token limit is a quota.
  defp context_overflow?(400, provider_error, message) do
    text =
      [
        message,
        ResponseDecoder.error_field(provider_error, "message"),
        ResponseDecoder.error_field(provider_error, "status")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(text, "token") and
      (String.contains?(text, "limit") or String.contains?(text, "exceed"))
  end

  defp context_overflow?(_status, _provider_error, _message), do: false
end
