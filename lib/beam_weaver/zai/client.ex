defmodule BeamWeaver.ZAI.Client do
  @moduledoc """
  Z.ai OpenAI-compatible API client built on `BeamWeaver.Transport`.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.ZAI.Client.ResponseDecoder
  alias BeamWeaver.ZAI.Streaming

  @default_base_url "https://api.z.ai/api/paas/v4"
  @default_timeout 15_000

  defstruct base_url: @default_base_url,
            endpoint: @default_base_url <> "/chat/completions",
            chat_completions_endpoint: @default_base_url <> "/chat/completions",
            api_key: nil,
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: @default_timeout

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_url = Compat.configured_url(opts, :base_url, [:zai, :base_url], @default_base_url)
    chat_endpoint = endpoint(base_url, "chat/completions")

    %__MODULE__{
      base_url: base_url,
      endpoint: Keyword.get(opts, :endpoint, chat_endpoint),
      chat_completions_endpoint: Keyword.get(opts, :chat_completions_endpoint, chat_endpoint),
      api_key: Config.option(opts, :api_key, [:zai, :api_key]),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  @spec chat_completions(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def chat_completions(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> HTTPClient.post_json(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @spec chat_completions_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> HTTPClient.stream_sse(body, opts, &Streaming.text_deltas/1, &ResponseDecoder.text_stream/1)
  end

  @spec chat_completions_stream_response(t(), map(), keyword()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, Error.t()}
  def chat_completions_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> HTTPClient.collect_sse(body, opts, &ResponseDecoder.stream_message(&1, opts))
  end

  @spec chat_completions_stream_typed_events(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    finish = &ResponseDecoder.finish_typed_events(&1, &2, opts)

    client
    |> http(client.chat_completions_endpoint, opts)
    |> HTTPClient.stream_typed_sse(
      body,
      Keyword.put(opts, :parser_finalizer, finish),
      &Streaming.typed_events/2,
      &ResponseDecoder.typed_events/1
    )
  end

  @spec request(t(), map(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> HTTPClient.request(body, opts)

  @doc "Returns a Z.ai API endpoint for a base URL and path."
  @spec endpoint(String.t(), String.t()) :: String.t()
  def endpoint(base_url, path), do: Compat.endpoint(base_url, path)

  defp http(client, endpoint, opts),
    do: Compat.http(:zai, client, endpoint, opts, [Compat.user_agent(opts, "beam_weaver-zai/0.1")])
end
