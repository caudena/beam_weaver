defmodule BeamWeaver.XAI.Client do
  @moduledoc """
  xAI OpenAI-compatible API client built on `BeamWeaver.Transport`.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.Streaming
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Provider.OpenAICompatibleStreaming
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.XAI.Client.ResponseDecoder
  alias BeamWeaver.XAI.Messages

  @default_base_url "https://api.x.ai/v1"
  @default_timeout 15_000

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
  def responses(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.endpoint, opts)
    |> HTTPClient.post_json(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @spec post_json(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def post_json(%__MODULE__{} = client, endpoint, body, opts \\ []) when is_binary(endpoint) and is_map(body) do
    client
    |> http(endpoint, opts)
    |> HTTPClient.post_json(body, Keyword.put(opts, :endpoint, endpoint))
    |> ResponseDecoder.json(opts)
  end

  @spec responses_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.endpoint, opts)
    |> HTTPClient.stream_sse(body, opts, &Streaming.text_deltas/1, &ResponseDecoder.text_stream/1)
  end

  @spec responses_stream_response(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def responses_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.endpoint, opts)
    |> HTTPClient.collect_sse(body, opts, &ResponseDecoder.responses_stream_map(&1, opts))
  end

  @spec responses_stream_events(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.endpoint, opts)
    |> HTTPClient.stream_sse(body, opts, &Streaming.lifecycle_events/1, &ResponseDecoder.lifecycle_events/1)
  end

  @spec responses_stream_typed_events(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.endpoint, opts)
    |> HTTPClient.stream_typed_sse(body, opts, &responses_typed_events/1, &ResponseDecoder.typed_events/1)
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

  @spec chat_completions_stream_response(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def chat_completions_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> HTTPClient.collect_sse(body, opts, &ResponseDecoder.chat_completions_stream_response(&1, opts))
  end

  @spec chat_completions_stream_typed_events(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    finish = &ResponseDecoder.finish_chat_completions_typed_events(&1, &2, opts)

    client
    |> http(client.chat_completions_endpoint, opts)
    |> HTTPClient.stream_typed_sse(
      body,
      Keyword.put(opts, :parser_finalizer, finish),
      &chat_completions_typed_events/2,
      &ResponseDecoder.typed_events/1
    )
  end

  # Like a Responses stream, the stream ends with the complete reply, decoded
  # like a reply from `chat_completions/3`, followed by its `Done` events.
  defp chat_completions_typed_events(events, state),
    do: events |> Streaming.typed_events() |> OpenAICompatibleStreaming.hold_events(events, state)

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
        with {:ok, body} <- ResponseDecoder.json({:ok, %{response | status: 200}}, opts) do
          {:ok, {:pending, body}}
        end

      result ->
        ResponseDecoder.json(result, opts)
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
end
