defmodule BeamWeaver.Provider.HTTPClient do
  @moduledoc false

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Core.Error
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

  # Every call checks the credentials first: a provider that needs an API key
  # gets `{:error, %Error{type: :missing_api_key}}` without any HTTP request
  # when none is configured.

  @spec post_json(t(), map(), keyword()) :: Transport.result() | {:error, Error.t()}
  def post_json(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    with {:ok, client} <- authenticate(client, opts) do
      client
      |> request(body, opts)
      |> do_request(client, opts)
    end
  end

  @spec get(t(), keyword()) :: Transport.result() | {:error, Error.t()}
  def get(%__MODULE__{} = client, opts \\ []) do
    with {:ok, client} <- authenticate(client, opts) do
      client
      |> get_request(opts)
      |> do_request(client, opts)
    end
  end

  @type json_body :: map() | binary()

  @spec stream_sse(
          t(),
          json_body(),
          keyword(),
          Streaming.parser(),
          Streaming.error_decoder()
        ) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_sse(%__MODULE__{} = client, body, opts, parser, error_decoder)
      when (is_map(body) or is_binary(body)) and
             (is_function(parser, 1) or is_function(parser, 2)) and
             is_function(error_decoder, 1) do
    with {:ok, client} <- authenticate(client, opts) do
      request = request(client, body, opts)

      stream =
        Streaming.live_sse(
          transport(client),
          request,
          transport_opts(client, request, opts),
          Keyword.put(opts, :provider, client.provider),
          parser,
          error_decoder
        )

      {:ok, stream}
    end
  end

  @doc """
  Like `stream_sse/5`, for a parser of typed events: every item of the stream
  is a `BeamWeaver.Stream.Envelope`, including the `Error` event that ends a
  failed stream.
  """
  @spec stream_typed_sse(
          t(),
          json_body(),
          keyword(),
          Streaming.parser(),
          Streaming.error_decoder()
        ) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_typed_sse(%__MODULE__{} = client, body, opts, parser, error_decoder) do
    with {:ok, stream} <- stream_sse(client, body, opts, parser, error_decoder) do
      {:ok, Stream.map(stream, &typed_item(&1, client.provider))}
    end
  end

  defp typed_item(%BeamWeaver.Stream.Envelope{} = envelope, _provider), do: envelope
  defp typed_item(event, provider), do: BeamWeaver.Stream.envelope(event, metadata: %{provider: provider})

  @spec collect_sse(t(), json_body(), keyword(), Streaming.error_decoder()) ::
          {:ok, term()} | {:error, term()}
  def collect_sse(%__MODULE__{} = client, body, opts, decoder)
      when (is_map(body) or is_binary(body)) and is_function(decoder, 1) do
    with {:ok, client} <- authenticate(client, opts) do
      request = request(client, body, opts)

      Streaming.collect(
        transport(client),
        request,
        transport_opts(client, request, opts),
        decoder,
        provider: client.provider
      )
    end
  end

  @spec request(t(), json_body(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) when is_map(body) or is_binary(body) do
    timeout = Keyword.get(opts, :timeout, client.timeout)

    request_options =
      [
        method: :post,
        url: Keyword.get(opts, :endpoint, client.endpoint),
        headers: headers(client, opts),
        options: [timeout: timeout]
      ]

    Request.new(
      if(is_binary(body),
        do: Keyword.put(request_options, :body, body),
        else: Keyword.put(request_options, :json, body)
      )
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

  # Resolves a function API key once, so the request sends the value that was
  # checked. Credentials passed as a header (the provider's key header, or an
  # `authorization` bearer token in `default_headers`) count as present.
  defp authenticate(%__MODULE__{auth_header: nil} = client, _opts), do: {:ok, client}

  defp authenticate(%__MODULE__{} = client, opts) do
    api_key = resolve_api_key(client.api_key)

    cond do
      api_key not in [nil, ""] ->
        {:ok, %{client | api_key: api_key}}

      auth_header_given?(client, opts) ->
        {:ok, %{client | api_key: nil}}

      true ->
        {:error, missing_api_key_error(client.provider)}
    end
  end

  defp resolve_api_key(api_key) when is_function(api_key, 0), do: resolve_api_key(api_key.())
  defp resolve_api_key(api_key) when is_binary(api_key), do: String.trim(api_key)
  defp resolve_api_key(_api_key), do: nil

  defp auth_header_given?(%__MODULE__{} = client, opts) do
    names = ["authorization", String.downcase(client.auth_header)]

    (Request.normalize_headers(client.default_headers) ++ Request.normalize_headers(Keyword.get(opts, :headers, [])))
    |> Enum.any?(fn {header, value} -> header in names and value not in [nil, ""] end)
  end

  defp missing_api_key_error(provider) do
    Error.new(
      :missing_api_key,
      "#{provider_label(provider)} API key is missing; set config :beam_weaver, #{inspect(provider)}, " <>
        "api_key: ... or pass api_key:",
      %{provider: provider, retryable: false}
    )
  end

  @doc false
  # The provider's name in messages.
  @spec provider_label(atom()) :: String.t()
  def provider_label(:openai), do: "OpenAI"
  def provider_label(:anthropic), do: "Anthropic"
  def provider_label(:google), do: "Google"
  def provider_label(:xai), do: "xAI"
  def provider_label(:moonshot), do: "Moonshot"
  def provider_label(:zai), do: "Z.ai"
  def provider_label(:deepseek), do: "DeepSeek"
  def provider_label(:typesafe), do: "TypeSafe"
  def provider_label(provider), do: to_string(provider)

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
