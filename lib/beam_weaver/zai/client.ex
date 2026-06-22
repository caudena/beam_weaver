defmodule BeamWeaver.ZAI.Client do
  @moduledoc """
  Z.ai OpenAI-compatible API client built on `BeamWeaver.Transport`.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Provider.OpenAICompatibleClient
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.ZAI.Client.ResponseDecoder
  alias BeamWeaver.ZAI.Error

  @default_base_url "https://api.z.ai/api/paas/v4"
  @default_chat_completions_endpoint @default_base_url <> "/chat/completions"
  @default_timeout 15_000

  defstruct base_url: @default_base_url,
            endpoint: @default_chat_completions_endpoint,
            chat_completions_endpoint: @default_chat_completions_endpoint,
            api_key: nil,
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: @default_timeout

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    base_url = base_url(opts)

    struct(__MODULE__,
      base_url: base_url,
      endpoint: Keyword.get(opts, :endpoint, endpoint(base_url, "chat/completions")),
      chat_completions_endpoint: Keyword.get(opts, :chat_completions_endpoint, endpoint(base_url, "chat/completions")),
      api_key: Config.option(opts, :api_key, [:zai, :api_key]),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    )
  end

  @spec chat_completions(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def chat_completions(client_or_opts, body, opts \\ []) when is_map(body) do
    client =
      client_or_opts
      |> normalize_client(Keyword.put_new(opts, :endpoint, chat_completions_endpoint(client_or_opts)))

    endpoint = Keyword.get(opts, :endpoint, client.chat_completions_endpoint)

    client
    |> do_request(body, Keyword.put(opts, :endpoint, endpoint))
    |> ResponseDecoder.json(opts)
  end

  @spec chat_completions_stream(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream(client_or_opts, body, opts \\ []) when is_map(body) do
    client =
      client_or_opts
      |> normalize_client(Keyword.put_new(opts, :endpoint, chat_completions_endpoint(client_or_opts)))

    endpoint = Keyword.get(opts, :endpoint, client.chat_completions_endpoint)

    client
    |> do_stream(
      body,
      Keyword.put(opts, :endpoint, endpoint),
      &BeamWeaver.ZAI.Streaming.text_deltas/1,
      &ResponseDecoder.text_stream/1
    )
  end

  @spec chat_completions_stream_response(t() | keyword(), map(), keyword()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, Error.t()}
  def chat_completions_stream_response(client_or_opts, body, opts \\ []) when is_map(body) do
    client =
      client_or_opts
      |> normalize_client(Keyword.put_new(opts, :endpoint, chat_completions_endpoint(client_or_opts)))

    endpoint = Keyword.get(opts, :endpoint, client.chat_completions_endpoint)

    client
    |> do_stream_collect(
      body,
      Keyword.put(opts, :endpoint, endpoint),
      &ResponseDecoder.stream_message(&1, opts)
    )
  end

  @spec chat_completions_stream_typed_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream_typed_events(client_or_opts, body, opts \\ []) when is_map(body) do
    client =
      client_or_opts
      |> normalize_client(Keyword.put_new(opts, :endpoint, chat_completions_endpoint(client_or_opts)))

    endpoint = Keyword.get(opts, :endpoint, client.chat_completions_endpoint)

    client
    |> do_stream(
      body,
      Keyword.put(opts, :endpoint, endpoint),
      &BeamWeaver.ZAI.Streaming.typed_events/1,
      &ResponseDecoder.typed_events/1
    )
  end

  @spec request(t(), map(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    OpenAICompatibleClient.request(client, body, opts, &http_client/2)
  end

  @doc "Returns a Z.ai API endpoint for a base URL and path."
  @spec endpoint(String.t(), String.t()) :: String.t()
  def endpoint(base_url, path) do
    OpenAICompatibleClient.endpoint(base_url, path)
  end

  defp do_request(%__MODULE__{} = client, body, opts) do
    OpenAICompatibleClient.post_json(client, body, opts, &http_client/2)
  end

  defp do_stream(%__MODULE__{} = client, body, opts, parser, error_decoder) do
    OpenAICompatibleClient.stream_sse(client, body, opts, &http_client/2, parser, error_decoder)
  end

  defp do_stream_collect(%__MODULE__{} = client, body, opts, decoder) do
    OpenAICompatibleClient.collect_sse(client, body, opts, &http_client/2, decoder)
  end

  defp http_client(%__MODULE__{} = client, opts) do
    OpenAICompatibleClient.http_client(:zai, client, opts,
      auth_header: "authorization",
      auth_prefix: "Bearer",
      default_headers: headers(client, opts)
    )
  end

  defp headers(%__MODULE__{} = client, opts) do
    [{"user-agent", Keyword.get(opts, :user_agent, "beam_weaver-zai/0.1")}]
    |> Kernel.++(Request.normalize_headers(client.default_headers))
    |> Kernel.++(Request.normalize_headers(Keyword.get(opts, :headers, [])))
  end

  defp normalize_client(client_or_opts, opts),
    do:
      OpenAICompatibleClient.normalize_client(client_or_opts, opts, &new/1, [
        :base_url,
        :endpoint,
        :chat_completions_endpoint,
        :api_key,
        :default_headers,
        :transport,
        :transport_opts,
        :timeout
      ])

  defp base_url(opts) do
    if Keyword.has_key?(opts, :base_url) do
      Keyword.fetch!(opts, :base_url) || @default_base_url
    else
      Config.get([:zai, :base_url], @default_base_url)
    end
  end

  defp chat_completions_endpoint(client_or_opts) do
    OpenAICompatibleClient.chat_completions_endpoint(client_or_opts, fn opts ->
      endpoint(base_url(opts), "chat/completions")
    end)
  end
end
