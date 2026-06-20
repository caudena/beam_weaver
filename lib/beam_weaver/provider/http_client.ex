defmodule BeamWeaver.Provider.HTTPClient do
  @moduledoc false

  alias BeamWeaver.Provider.HTTPMetadata
  alias BeamWeaver.Provider.Options
  alias BeamWeaver.Provider.Streaming
  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.Request

  defstruct provider: nil,
            endpoint: nil,
            api_key: nil,
            auth_header: nil,
            auth_prefix: nil,
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__,
      provider: Keyword.get(opts, :provider),
      endpoint: Keyword.get(opts, :endpoint),
      api_key: Keyword.get(opts, :api_key),
      auth_header: Keyword.get(opts, :auth_header),
      auth_prefix: Keyword.get(opts, :auth_prefix),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: Options.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, 15_000)
    )
  end

  @spec post_json(t(), map(), keyword()) :: Transport.result()
  def post_json(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> request(body, opts)
    |> do_request(client, opts)
  end

  @spec get(t(), keyword()) :: Transport.result()
  def get(%__MODULE__{} = client, opts \\ []) do
    client
    |> get_request(opts)
    |> do_request(client, opts)
  end

  @spec stream_sse(
          t(),
          map(),
          keyword(),
          ([map()] -> [term()]),
          Streaming.error_decoder()
        ) :: {:ok, Enumerable.t()}
  def stream_sse(%__MODULE__{} = client, body, opts, parser, error_decoder)
      when is_map(body) and is_function(parser, 1) and is_function(error_decoder, 1) do
    request = request(client, body, opts)

    stream =
      Streaming.live_sse(
        transport(client),
        request,
        transport_opts(client, request, opts),
        opts,
        parser,
        error_decoder
      )

    {:ok, stream}
  end

  @spec collect_sse(t(), map(), keyword(), Streaming.error_decoder()) ::
          {:ok, term()} | {:error, term()}
  def collect_sse(%__MODULE__{} = client, body, opts, decoder)
      when is_map(body) and is_function(decoder, 1) do
    request = request(client, body, opts)

    Streaming.collect(
      transport(client),
      request,
      transport_opts(client, request, opts),
      decoder
    )
  end

  @spec request(t(), map(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    timeout = Keyword.get(opts, :timeout, client.timeout)

    Request.new(
      method: :post,
      url: Keyword.get(opts, :endpoint, client.endpoint),
      headers: headers(client, opts),
      json: body,
      options: [timeout: timeout]
    )
  end

  @spec get_request(t(), keyword()) :: Request.t()
  def get_request(%__MODULE__{} = client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, client.timeout)

    Request.new(
      method: :get,
      url: Keyword.get(opts, :endpoint, client.endpoint),
      headers: headers(client, opts),
      options: [timeout: timeout]
    )
  end

  defp do_request(%Request{} = request, %__MODULE__{} = client, opts) do
    Transport.request(transport(client), request, transport_opts(client, request, opts))
  end

  defp transport(%__MODULE__{} = client), do: Options.default_transport(client.transport)

  @spec transport_opts(t(), Request.t(), keyword()) :: keyword()
  def transport_opts(%__MODULE__{} = client, %Request{} = request, opts) do
    timeout = Keyword.get(opts, :timeout, client.timeout)

    transport_opts = client.transport_opts |> Keyword.merge(opts) |> Keyword.put(:timeout, timeout)

    Keyword.put(
      transport_opts,
      :beam_weaver_http_metadata,
      HTTPMetadata.build(client.provider, request, timeout: Keyword.get(transport_opts, :timeout))
    )
  end

  defp headers(%__MODULE__{} = client, opts) do
    [
      {"content-type", "application/json"}
    ]
    |> maybe_put_auth(client.auth_header, client.auth_prefix, client.api_key)
    |> Kernel.++(Request.normalize_headers(client.default_headers))
    |> Kernel.++(Request.normalize_headers(Keyword.get(opts, :headers, [])))
  end

  defp maybe_put_auth(headers, nil, _prefix, _api_key), do: headers
  defp maybe_put_auth(headers, _header, _prefix, nil), do: headers
  defp maybe_put_auth(headers, _header, _prefix, ""), do: headers

  defp maybe_put_auth(headers, header, prefix, api_key) when is_function(api_key, 0) do
    maybe_put_auth(headers, header, prefix, api_key.())
  end

  defp maybe_put_auth(headers, header, nil, api_key), do: [{header, api_key} | headers]

  defp maybe_put_auth(headers, header, prefix, api_key),
    do: [{header, "#{prefix} #{api_key}"} | headers]
end
