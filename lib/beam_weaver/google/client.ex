defmodule BeamWeaver.Google.Client do
  @moduledoc """
  Google Gemini Developer API client built on `BeamWeaver.Transport`.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Google.Error
  alias BeamWeaver.Google.Streaming
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Provider.Streaming, as: ProviderStreaming
  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.Request

  @default_base_url "https://generativelanguage.googleapis.com/v1beta"

  defstruct base_url: @default_base_url,
            api_key: nil,
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    %__MODULE__{
      base_url: base_url(opts),
      api_key: Config.option(opts, :api_key, [:google, :api_key]),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, 15_000)
    }
  end

  defp base_url(opts) do
    cond do
      Keyword.has_key?(opts, :base_url) ->
        Keyword.fetch!(opts, :base_url) || Keyword.get(opts, :endpoint) || @default_base_url

      Keyword.has_key?(opts, :endpoint) ->
        Keyword.fetch!(opts, :endpoint) || @default_base_url

      true ->
        Config.get([:google, :base_url], @default_base_url)
    end
  end

  @spec generate_content(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def generate_content(%__MODULE__{} = client, model, body, opts \\ []) do
    client
    |> request(model, :generate_content, body, opts)
    |> do_json_request(client, opts)
  end

  @spec count_tokens(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def count_tokens(%__MODULE__{} = client, model, body, opts \\ []) do
    client
    |> request(model, :count_tokens, body, opts)
    |> do_json_request(client, opts)
  end

  @spec stream_text(t(), String.t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_text(%__MODULE__{} = client, model, body, opts \\ []) do
    request = request(client, model, :stream_generate_content, body, opts)

    stream =
      ProviderStreaming.live_sse(
        transport(client),
        request,
        transport_opts(client, opts),
        opts,
        &Streaming.text_deltas/1,
        &decode_result(&1, opts)
      )

    {:ok, stream}
  end

  @spec stream_response(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def stream_response(%__MODULE__{} = client, model, body, opts \\ []) do
    request = request(client, model, :stream_generate_content, body, opts)

    ProviderStreaming.collect(
      transport(client),
      request,
      transport_opts(client, opts),
      &decode_sse_result(&1, opts)
    )
  end

  @spec stream_events(t(), String.t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_events(%__MODULE__{} = client, model, body, opts \\ []) do
    request = request(client, model, :stream_generate_content, body, opts)

    stream =
      ProviderStreaming.live_sse(
        transport(client),
        request,
        transport_opts(client, opts),
        opts,
        &Streaming.typed_events/1,
        &decode_result(&1, opts)
      )

    {:ok, stream}
  end

  @spec request(t(), String.t(), atom(), map(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, model, action, body, opts \\ []) do
    Request.new(
      method: :post,
      url: endpoint(client, model, action),
      headers: headers(client, opts),
      json: body,
      options: [timeout: Keyword.get(opts, :timeout, client.timeout)]
    )
  end

  def endpoint(%__MODULE__{base_url: base_url}, model, action) do
    base = String.trim_trailing(base_url, "/")
    encoded_model = URI.encode(model, &URI.char_unreserved?/1)

    case action do
      :generate_content -> "#{base}/models/#{encoded_model}:generateContent"
      :stream_generate_content -> "#{base}/models/#{encoded_model}:streamGenerateContent?alt=sse"
      :count_tokens -> "#{base}/models/#{encoded_model}:countTokens"
    end
  end

  defp do_json_request(%Request{} = request, %__MODULE__{} = client, opts) do
    client
    |> transport()
    |> Transport.request(request, transport_opts(client, opts))
    |> decode_result(opts)
  end

  defp transport(%__MODULE__{} = client), do: ProviderOptions.default_transport(client.transport)

  defp decode_result(result, opts) do
    ResponseDecoder.json(result,
      provider: :google,
      error_module: Error,
      request_id_header: "x-request-id",
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      context_overflow?: &context_overflow?/3
    )
  end

  defp decode_sse_result({:ok, %BeamWeaver.Transport.Response{status: status, body: body}}, _opts)
       when status in 200..299 do
    {:ok, Streaming.response_from_sse_body(body)}
  end

  defp decode_sse_result(result, opts), do: decode_result(result, opts)

  defp headers(%__MODULE__{} = client, opts) do
    [
      {"content-type", "application/json"},
      {"user-agent", Keyword.get(opts, :user_agent, "beam_weaver-google/0.1")}
    ]
    |> maybe_put_api_key(client.api_key)
    |> Kernel.++(BeamWeaver.Transport.Request.normalize_headers(client.default_headers))
    |> Kernel.++(BeamWeaver.Transport.Request.normalize_headers(Keyword.get(opts, :headers, [])))
  end

  defp maybe_put_api_key(headers, nil), do: headers
  defp maybe_put_api_key(headers, ""), do: headers

  defp maybe_put_api_key(headers, api_key) when is_function(api_key, 0),
    do: maybe_put_api_key(headers, api_key.())

  defp maybe_put_api_key(headers, api_key), do: [{"x-goog-api-key", api_key} | headers]

  defp transport_opts(%__MODULE__{} = client, opts) do
    timeout = Keyword.get(opts, :timeout, client.timeout)
    client.transport_opts ++ Keyword.put_new(opts, :timeout, timeout)
  end

  defp context_overflow?(_status, provider_error, message) do
    text =
      [
        message,
        error_field(provider_error, "message"),
        error_field(provider_error, "status")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(text, "token") and
      (String.contains?(text, "limit") or String.contains?(text, "exceed"))
  end

  defp error_field(%{} = error, field),
    do: BeamWeaver.MapAccess.get(error, field)

  defp error_field(_error, _field), do: nil
end
