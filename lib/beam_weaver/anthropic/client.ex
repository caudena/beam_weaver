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
    |> ResponseDecoder.json(decoder_opts(opts))
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
    |> HTTPClient.stream_sse(body, opts, parser, &decode_stream(&1, parser))
  end

  defp do_stream_collect(%__MODULE__{} = client, body, opts, parser) do
    client
    |> http_client(opts)
    |> HTTPClient.collect_sse(body, opts, &decode_stream(&1, parser))
  end

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

  defp decode_stream({:ok, %Response{status: status, body: body}}, parser)
       when status in 200..299,
       do: {:ok, parser.(body)}

  defp decode_stream({:ok, %Response{} = response}, _parser),
    do: {:error, ResponseDecoder.http_error(response, decoder_opts())}

  defp decode_stream({:error, error}, _parser),
    do: {:error, ResponseDecoder.transport_error(error, decoder_opts())}

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
