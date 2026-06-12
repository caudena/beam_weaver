defmodule BeamWeaver.XAI.Client do
  @moduledoc """
  xAI OpenAI-compatible API client built on `BeamWeaver.Transport`.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Provider.OpenAICompatibleClient
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.XAI.Client.ResponseDecoder
  alias BeamWeaver.XAI.Error

  @default_base_url "https://api.x.ai/v1"
  @default_responses_endpoint @default_base_url <> "/responses"
  @default_chat_completions_endpoint @default_base_url <> "/chat/completions"
  @default_deferred_completion_endpoint @default_base_url <> "/chat/deferred-completion"
  @default_timeout 15_000

  defstruct base_url: @default_base_url,
            endpoint: @default_responses_endpoint,
            chat_completions_endpoint: @default_chat_completions_endpoint,
            deferred_completion_endpoint: @default_deferred_completion_endpoint,
            api_key: nil,
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: @default_timeout

  @type t :: %__MODULE__{}

  @doc """
  Builds a client from keyword options and xAI environment defaults.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_url = base_url(opts)

    struct(__MODULE__,
      base_url: base_url,
      endpoint: Keyword.get(opts, :endpoint, endpoint(base_url, "responses")),
      chat_completions_endpoint: Keyword.get(opts, :chat_completions_endpoint, endpoint(base_url, "chat/completions")),
      deferred_completion_endpoint:
        Keyword.get(
          opts,
          :deferred_completion_endpoint,
          endpoint(base_url, "chat/deferred-completion")
        ),
      api_key: Config.option(opts, :api_key, [:xai, :api_key]),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    )
  end

  defp base_url(opts) do
    if Keyword.has_key?(opts, :base_url) do
      Keyword.fetch!(opts, :base_url) || @default_base_url
    else
      Config.get([:xai, :base_url], @default_base_url)
    end
  end

  @spec responses(t() | keyword(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def responses(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_request(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @spec post_json(t() | keyword(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def post_json(client_or_opts, endpoint, body, opts \\ [])
      when is_binary(endpoint) and is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_request(body, Keyword.put(opts, :endpoint, endpoint))
    |> ResponseDecoder.json(opts)
  end

  @spec responses_stream(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_stream(
      body,
      opts,
      &BeamWeaver.OpenAI.Streaming.text_deltas/1,
      &ResponseDecoder.text_stream/1
    )
  end

  @spec responses_stream_response(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def responses_stream_response(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_stream_collect(body, opts, &ResponseDecoder.responses_stream_map(&1, opts))
  end

  @spec responses_stream_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_events(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_stream(
      body,
      opts,
      &BeamWeaver.OpenAI.Streaming.lifecycle_events/1,
      &ResponseDecoder.lifecycle_events/1
    )
  end

  @spec responses_stream_typed_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_typed_events(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_stream(
      body,
      opts,
      &BeamWeaver.OpenAI.Streaming.typed_events/1,
      &ResponseDecoder.typed_events/1
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
      &BeamWeaver.OpenAI.Streaming.text_deltas/1,
      &ResponseDecoder.text_stream/1
    )
  end

  @spec chat_completions_stream_response(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def chat_completions_stream_response(client_or_opts, body, opts \\ []) when is_map(body) do
    client =
      client_or_opts
      |> normalize_client(Keyword.put_new(opts, :endpoint, chat_completions_endpoint(client_or_opts)))

    endpoint = Keyword.get(opts, :endpoint, client.chat_completions_endpoint)

    client
    |> do_stream_collect(
      body,
      Keyword.put(opts, :endpoint, endpoint),
      &ResponseDecoder.chat_completions_stream_response(&1, opts)
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
      &BeamWeaver.OpenAI.Streaming.typed_events/1,
      &ResponseDecoder.typed_events/1
    )
  end

  @doc """
  Retrieves the status/result of a deferred xAI chat-completions request.
  """
  @spec deferred_completion(t() | keyword(), String.t(), keyword()) ::
          {:ok, map() | {:pending, map()}} | {:error, Error.t()}
  def deferred_completion(client_or_opts, request_id, opts \\ []) when is_binary(request_id) do
    client = normalize_client(client_or_opts, opts)

    endpoint =
      Keyword.get(opts, :endpoint, "#{client.deferred_completion_endpoint}/#{request_id}")

    case do_get(client, Keyword.put(opts, :endpoint, endpoint)) do
      {:ok, %BeamWeaver.Transport.Response{status: 202} = response} ->
        case ResponseDecoder.json({:ok, %{response | status: 200}}, opts) do
          {:ok, body} -> {:ok, {:pending, body}}
          {:error, _error} = error -> error
        end

      result ->
        ResponseDecoder.json(result, opts)
    end
  end

  @spec request(t(), map(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    OpenAICompatibleClient.request(client, body, opts, &http_client/2)
  end

  @doc """
  Returns an xAI API endpoint for a base URL and path.
  """
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

  defp do_get(%__MODULE__{} = client, opts) do
    OpenAICompatibleClient.get(client, opts, &http_client/2)
  end

  defp http_client(%__MODULE__{} = client, opts) do
    OpenAICompatibleClient.http_client(:xai, client, opts,
      auth_header: "authorization",
      auth_prefix: "Bearer",
      default_headers: headers(client, opts)
    )
  end

  defp headers(%__MODULE__{} = client, _opts) do
    client.default_headers
    |> BeamWeaver.Transport.Request.normalize_headers()
  end

  defp normalize_client(client_or_opts, opts),
    do:
      OpenAICompatibleClient.normalize_client(client_or_opts, opts, &new/1, [
        :base_url,
        :endpoint,
        :chat_completions_endpoint,
        :deferred_completion_endpoint,
        :api_key,
        :default_headers,
        :transport,
        :transport_opts,
        :timeout
      ])

  defp chat_completions_endpoint(client_or_opts) do
    OpenAICompatibleClient.chat_completions_endpoint(client_or_opts, fn opts ->
      endpoint(base_url(opts), "chat/completions")
    end)
  end
end
