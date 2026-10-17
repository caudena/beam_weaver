defmodule BeamWeaver.XAI.Client do
  @moduledoc """
  xAI OpenAI-compatible API client built on `BeamWeaver.Transport`.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.Client, as: OpenAIClient
  alias BeamWeaver.OpenAI.Client.ResponseDecoder
  alias BeamWeaver.OpenAI.Streaming
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.XAI.Messages

  @default_base_url "https://api.x.ai/v1"
  @default_timeout 15_000

  @header_fields [
    request_id: "x-request-id",
    x_ratelimit_limit_requests: "x-ratelimit-limit-requests",
    x_ratelimit_limit_tokens: "x-ratelimit-limit-tokens",
    x_ratelimit_remaining_requests: "x-ratelimit-remaining-requests",
    x_ratelimit_remaining_tokens: "x-ratelimit-remaining-tokens",
    x_zero_data_retention: "x-zero-data-retention",
    x_metrics_e2e_ms: "x-metrics-e2e-ms",
    x_metrics_mean_itl_ms: "x-metrics-mean-itl-ms",
    x_metrics_ttft_ms: "x-metrics-ttft-ms"
  ]

  defstruct base_url: @default_base_url,
            endpoint: @default_base_url <> "/responses",
            chat_completions_endpoint: @default_base_url <> "/chat/completions",
            deferred_completion_endpoint: @default_base_url <> "/chat/deferred-completion",
            api_key: nil,
            x_grok_conv_id: nil,
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
    base_url = Compat.configured_url(opts, :base_url, [:xai, :base_url], @default_base_url)

    %__MODULE__{
      base_url: base_url,
      endpoint: Keyword.get(opts, :endpoint, endpoint(base_url, "responses")),
      chat_completions_endpoint: Keyword.get(opts, :chat_completions_endpoint, endpoint(base_url, "chat/completions")),
      deferred_completion_endpoint:
        Keyword.get(opts, :deferred_completion_endpoint, endpoint(base_url, "chat/deferred-completion")),
      api_key: Config.option(opts, :api_key, [:xai, :api_key]),
      x_grok_conv_id: Keyword.get(opts, :x_grok_conv_id),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  @spec responses(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def responses(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> OpenAIClient.post(body, opts, decoder())

  @spec post_json(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def post_json(%__MODULE__{} = client, endpoint, body, opts \\ []) when is_binary(endpoint) and is_map(body),
    do: client |> http(endpoint, opts) |> OpenAIClient.post(body, Keyword.put(opts, :endpoint, endpoint), decoder())

  @spec responses_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> OpenAIClient.stream_text(body, opts, decoder())

  @spec responses_stream_response(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def responses_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> OpenAIClient.collect_response(body, opts, decoder())

  @spec responses_stream_events(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> OpenAIClient.stream_lifecycle(body, opts, decoder())

  @spec responses_stream_typed_events(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.endpoint, opts)
    |> OpenAIClient.stream_typed(body, opts, decoder(), &responses_typed_events/1)
  end

  # The stream ends with the complete reply, which carries the same xAI
  # metadata as a reply from `responses/3`.
  defp responses_typed_events(events) do
    events
    |> Streaming.typed_events()
    |> Enum.map(fn
      %Envelope{event: %Events.Message{message: message} = event} = envelope ->
        %{envelope | event: %{event | message: Messages.put_responses_metadata(message)}}

      envelope ->
        envelope
    end)
  end

  @spec chat_completions(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def chat_completions(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.chat_completions_endpoint, opts) |> OpenAIClient.post(body, opts, decoder())

  @spec chat_completions_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.chat_completions_endpoint, opts) |> OpenAIClient.stream_text(body, opts, decoder())

  @spec chat_completions_stream_response(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def chat_completions_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> OpenAIClient.collect_chat_completion(body, opts, decoder())
  end

  # Like a Responses stream, the stream ends with the complete reply, decoded
  # like a reply from `chat_completions/3`, followed by its `Done` events.
  @spec chat_completions_stream_typed_events(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> OpenAIClient.stream_chat_completion(body, opts, decoder(), &Messages.chat_completions_to_message/1)
  end

  @doc """
  Retrieves the status/result of a deferred xAI chat-completions request.
  """
  @spec deferred_completion(t(), String.t(), keyword()) ::
          {:ok, map() | {:pending, map()}} | {:error, Error.t()}
  def deferred_completion(%__MODULE__{} = client, request_id, opts \\ []) when is_binary(request_id) do
    result =
      client
      |> http("#{client.deferred_completion_endpoint}/#{request_id}", opts)
      |> HTTPClient.get(opts)

    case result do
      {:ok, %BeamWeaver.Transport.Response{status: 202} = response} ->
        with {:ok, body} <- ResponseDecoder.json({:ok, %{response | status: 200}}, opts, decoder()) do
          {:ok, {:pending, body}}
        end

      result ->
        ResponseDecoder.json(result, opts, decoder())
    end
  end

  @spec request(t(), map(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> HTTPClient.request(body, opts)

  @doc """
  Returns an xAI API endpoint for a base URL and path.
  """
  @spec endpoint(String.t(), String.t()) :: String.t()
  def endpoint(base_url, path), do: Compat.endpoint(base_url, path)

  defp http(client, endpoint, opts) do
    headers =
      case Keyword.get(opts, :x_grok_conv_id, client.x_grok_conv_id) do
        value when value in [nil, ""] -> []
        value -> [{"x-grok-conv-id", to_string(value)}]
      end

    Compat.http(:xai, client, endpoint, opts, headers)
  end

  # xAI speaks the OpenAI wire format; only headers and naming differ.
  defp decoder, do: %{provider: :xai, provider_name: "xAI", header_fields: @header_fields, error_type: &error_type/3}

  # xAI documents a wrong API key as a 400.
  defp error_type(400, _provider_error, "Incorrect API key" <> _rest), do: :authentication
  defp error_type(_status, _provider_error, _message), do: nil
end
