defmodule BeamWeaver.Anthropic.Client do
  @moduledoc """
  Anthropic Messages API client built on `BeamWeaver.Transport`.
  """

  alias BeamWeaver.Anthropic.Error
  alias BeamWeaver.Anthropic.Streaming
  alias BeamWeaver.Config
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Response

  @default_base_url "https://api.anthropic.com"
  @default_endpoint @default_base_url <> "/v1/messages"
  @default_count_tokens_endpoint @default_base_url <> "/v1/messages/count_tokens"
  @default_anthropic_version "2023-06-01"

  defstruct endpoint: @default_endpoint,
            count_tokens_endpoint: @default_count_tokens_endpoint,
            api_key: nil,
            anthropic_version: @default_anthropic_version,
            betas: [],
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__,
      endpoint: Keyword.get(opts, :endpoint, @default_endpoint),
      count_tokens_endpoint: Keyword.get(opts, :count_tokens_endpoint, @default_count_tokens_endpoint),
      api_key: Config.option(opts, :api_key, [:anthropic, :api_key]),
      anthropic_version: Keyword.get(opts, :anthropic_version, @default_anthropic_version),
      betas: List.wrap(Keyword.get(opts, :betas, [])),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, 15_000)
    )
  end

  @spec messages(t() | keyword(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def messages(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_request(body, opts)
    |> decode_result(opts)
  end

  @spec messages_stream(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def messages_stream(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_stream(body, opts, &Streaming.text_deltas/1)
  end

  @spec messages_stream_response(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def messages_stream_response(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_stream_collect(body, opts, &Streaming.response/1)
  end

  @spec messages_stream_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def messages_stream_events(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_stream(body, opts, &Streaming.lifecycle_events/1)
  end

  @spec messages_stream_typed_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def messages_stream_typed_events(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_stream(body, opts, &Streaming.typed_events/1)
  end

  @spec count_tokens(t() | keyword(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def count_tokens(client_or_opts, body, opts \\ []) when is_map(body) do
    client =
      client_or_opts
      |> normalize_client(opts)

    client
    |> do_request(body, Keyword.put(opts, :endpoint, client.count_tokens_endpoint))
    |> ResponseDecoder.json(decoder_opts(opts))
  end

  @spec request(t(), map(), keyword()) :: BeamWeaver.Transport.Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) do
    client |> http_client(opts) |> HTTPClient.request(body, opts)
  end

  @spec endpoint(String.t(), String.t()) :: String.t()
  def endpoint(base_url, path) do
    String.trim_trailing(to_string(base_url), "/") <> "/" <> String.trim_leading(path, "/")
  end

  defp do_request(%__MODULE__{} = client, body, opts) do
    client |> http_client(opts) |> HTTPClient.post_json(body, opts)
  end

  defp do_stream(%__MODULE__{} = client, body, opts, parser) do
    client
    |> http_client(opts)
    |> HTTPClient.stream_sse(body, opts, parser, &decode_stream(&1, parser, opts))
  end

  defp do_stream_collect(%__MODULE__{} = client, body, opts, parser) do
    client
    |> http_client(opts)
    |> HTTPClient.collect_sse(body, opts, &decode_stream(&1, parser, opts))
  end

  defp decode_result({:ok, %Response{} = response} = result, opts) do
    with {:ok, decoded} <- ResponseDecoder.json(result, decoder_opts(opts)) do
      decoded =
        if Keyword.get(opts, :decode_response_headers, true),
          do: attach_header_metadata(decoded, response.headers),
          else: decoded

      {:ok, decoded}
    end
  end

  defp decode_result(result, opts), do: ResponseDecoder.json(result, decoder_opts(opts))

  defp http_client(%__MODULE__{} = client, opts) do
    %HTTPClient{
      provider: :anthropic,
      endpoint: Keyword.get(opts, :endpoint, client.endpoint),
      api_key: Keyword.get(opts, :api_key, client.api_key),
      auth_header: "x-api-key",
      default_headers: headers(client, opts),
      transport: Keyword.get(opts, :transport, client.transport),
      transport_opts: Keyword.get(opts, :transport_opts, client.transport_opts),
      timeout: Keyword.get(opts, :timeout, client.timeout)
    }
  end

  defp headers(%__MODULE__{} = client, opts) do
    betas = Keyword.get(opts, :betas, client.betas) |> List.wrap() |> Enum.reject(&is_nil/1)

    [
      {"anthropic-version", Keyword.get(opts, :anthropic_version, client.anthropic_version)}
    ]
    |> maybe_put_beta_header(betas)
    |> Kernel.++(BeamWeaver.Transport.Request.normalize_headers(client.default_headers))
  end

  defp maybe_put_beta_header(headers, []), do: headers

  defp maybe_put_beta_header(headers, betas),
    do: [{"anthropic-beta", Enum.join(betas, ",")} | headers]

  defp normalize_client(%__MODULE__{} = client, opts), do: override_client(client, opts)

  defp normalize_client(opts, overrides) when is_list(opts),
    do: opts |> new() |> override_client(overrides)

  defp override_client(%__MODULE__{} = client, opts) do
    %{
      client
      | endpoint: Keyword.get(opts, :endpoint, client.endpoint),
        count_tokens_endpoint: Keyword.get(opts, :count_tokens_endpoint, client.count_tokens_endpoint),
        api_key: Keyword.get(opts, :api_key, client.api_key),
        anthropic_version: Keyword.get(opts, :anthropic_version, client.anthropic_version),
        betas: List.wrap(Keyword.get(opts, :betas, client.betas)),
        default_headers: Keyword.get(opts, :default_headers, client.default_headers),
        transport: Keyword.get(opts, :transport, client.transport),
        transport_opts: Keyword.get(opts, :transport_opts, client.transport_opts),
        timeout: Keyword.get(opts, :timeout, client.timeout)
    }
  end

  defp decode_stream({:ok, %Response{status: status, body: body} = response}, parser, opts)
       when status in 200..299 do
    {:ok, body |> parser.() |> maybe_attach_stream_headers(response, opts)}
  end

  defp decode_stream({:ok, %Response{} = response}, _parser, _opts),
    do: {:error, ResponseDecoder.http_error(response, decoder_opts())}

  defp decode_stream({:error, error}, _parser, _opts),
    do: {:error, ResponseDecoder.transport_error(error, decoder_opts())}

  defp maybe_attach_stream_headers(decoded, %Response{} = response, opts) when is_map(decoded) do
    decoded = attach_header_metadata(decoded, response.headers)

    if Keyword.get(opts, :include_response_headers, false),
      do: Map.put(decoded, "_beamweaver_response_headers", Map.new(response.headers)),
      else: decoded
  end

  defp maybe_attach_stream_headers(decoded, _response, _opts), do: decoded

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
        request_id: headers["request-id"],
        anthropic_organization_id: headers["anthropic-organization-id"],
        anthropic_ratelimit_input_tokens_limit: headers["anthropic-ratelimit-input-tokens-limit"],
        anthropic_ratelimit_input_tokens_remaining: headers["anthropic-ratelimit-input-tokens-remaining"],
        anthropic_ratelimit_input_tokens_reset: headers["anthropic-ratelimit-input-tokens-reset"],
        anthropic_ratelimit_output_tokens_limit: headers["anthropic-ratelimit-output-tokens-limit"],
        anthropic_ratelimit_output_tokens_remaining: headers["anthropic-ratelimit-output-tokens-remaining"],
        anthropic_ratelimit_output_tokens_reset: headers["anthropic-ratelimit-output-tokens-reset"],
        anthropic_ratelimit_requests_limit: headers["anthropic-ratelimit-requests-limit"],
        anthropic_ratelimit_requests_remaining: headers["anthropic-ratelimit-requests-remaining"],
        anthropic_ratelimit_requests_reset: headers["anthropic-ratelimit-requests-reset"],
        anthropic_ratelimit_tokens_limit: headers["anthropic-ratelimit-tokens-limit"],
        anthropic_ratelimit_tokens_remaining: headers["anthropic-ratelimit-tokens-remaining"],
        anthropic_ratelimit_tokens_reset: headers["anthropic-ratelimit-tokens-reset"]
      }
      |> reject_empty_header_values()

    %{headers: decoded, request_id: decoded[:request_id]}
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
      provider: :anthropic,
      error_module: Error,
      request_id_header: "request-id",
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      context_overflow?: &context_overflow?/3
    ]
  end

  defp context_overflow?(400, _provider_error, message) when is_binary(message) do
    normalized = String.downcase(message)

    String.contains?(normalized, "prompt is too long") or
      String.contains?(normalized, "context window") or
      String.contains?(normalized, "too many tokens")
  end

  defp context_overflow?(_status, _provider_error, _message), do: false
end
