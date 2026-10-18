defmodule BeamWeaver.DeepSeek.Client do
  @moduledoc ~S"""
  Native DeepSeek HTTP client using `BeamWeaver.Transport`.

  Use this layer when your application owns provider request/response shapes.
  It accepts native bodies and returns decoded provider data or tagged errors;
  the model facade supplies portable message normalization and compatibility
  checks. Transport/replay overrides do not establish live provider access.

  Configure this client's credentials for its actual endpoint. Keep raw request
  headers/bodies out of logs. Stream consumers own consumption and cancellation;
  collected-response helpers wait for completion. The [DeepSeek guide](providers/deepseek.md)
  identifies the implemented endpoints and external-resource lifetimes.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Anthropic.Streaming, as: AnthropicStreaming
  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.DeepSeek.Client.ResponseDecoder
  alias BeamWeaver.OpenAI.Streaming, as: OpenAIStreaming
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Provider.OpenAICompatibleStreaming
  alias BeamWeaver.Provider.Options, as: ProviderOptions

  @default_base_url "https://api.deepseek.com"
  @default_timeout 15_000

  defstruct base_url: @default_base_url,
            beta_base_url: @default_base_url <> "/beta",
            anthropic_base_url: @default_base_url <> "/anthropic",
            endpoint: @default_base_url <> "/chat/completions",
            chat_completions_endpoint: @default_base_url <> "/chat/completions",
            beta_chat_completions_endpoint: @default_base_url <> "/beta/chat/completions",
            responses_endpoint: @default_base_url <> "/responses",
            completions_endpoint: @default_base_url <> "/beta/completions",
            models_endpoint: @default_base_url <> "/models",
            balance_endpoint: @default_base_url <> "/user/balance",
            anthropic_messages_endpoint: @default_base_url <> "/anthropic/v1/messages",
            api_key: nil,
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: @default_timeout

  @type t :: %__MODULE__{}

  @doc "Builds a DeepSeek client from keyword options."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_url =
      opts
      |> Compat.configured_url(:base_url, [:deepseek, :base_url], @default_base_url)
      |> to_string()
      |> String.trim_trailing("/")

    api_root = api_root(base_url)
    base_url = if String.ends_with?(base_url, ["/beta", "/anthropic"]), do: api_root, else: base_url

    beta_base_url =
      Compat.configured_url(opts, :beta_base_url, [:deepseek, :beta_base_url], endpoint(api_root, "beta"))

    anthropic_base_url =
      Compat.configured_url(
        opts,
        :anthropic_base_url,
        [:deepseek, :anthropic_base_url],
        endpoint(api_root, "anthropic")
      )

    default_chat_endpoint = endpoint(base_url, "chat/completions")

    chat_completions_endpoint =
      Keyword.get(
        opts,
        :chat_completions_endpoint,
        Keyword.get(opts, :endpoint, default_chat_endpoint)
      )

    beta_chat_completions_endpoint =
      cond do
        Keyword.has_key?(opts, :beta_chat_completions_endpoint) -> Keyword.fetch!(opts, :beta_chat_completions_endpoint)
        chat_completions_endpoint != default_chat_endpoint -> chat_completions_endpoint
        true -> endpoint(beta_base_url, "chat/completions")
      end

    %__MODULE__{
      base_url: base_url,
      beta_base_url: beta_base_url,
      anthropic_base_url: anthropic_base_url,
      endpoint: Keyword.get(opts, :endpoint, chat_completions_endpoint),
      chat_completions_endpoint: chat_completions_endpoint,
      beta_chat_completions_endpoint: beta_chat_completions_endpoint,
      responses_endpoint: Keyword.get(opts, :responses_endpoint, endpoint(base_url, "responses")),
      completions_endpoint: Keyword.get(opts, :completions_endpoint, endpoint(beta_base_url, "completions")),
      models_endpoint: Keyword.get(opts, :models_endpoint, endpoint(base_url, "models")),
      balance_endpoint: Keyword.get(opts, :balance_endpoint, endpoint(base_url, "user/balance")),
      anthropic_messages_endpoint:
        Keyword.get(
          opts,
          :anthropic_messages_endpoint,
          endpoint(anthropic_base_url, "v1/messages")
        ),
      api_key: Config.option(opts, :api_key, [:deepseek, :api_key]),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  @doc """
  Sends a native JSON request and returns the decoded provider payload or a tagged HTTP/transport error.
  """
  @spec chat_completions(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def chat_completions(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(chat_endpoint(client, body, opts), opts)
    |> HTTPClient.post_json(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @doc """
  Sends a streaming request and returns text deltas. Consume the returned enumerable to execute streaming work.
  """
  @spec chat_completions_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(chat_endpoint(client, body, opts), opts)
    |> stream(body, opts, &OpenAICompatibleStreaming.text_deltas/1)
  end

  @doc """
  Collects the streaming provider response into its final decoded native payload, or returns an error.
  """
  @spec chat_completions_stream_response(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def chat_completions_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(chat_endpoint(client, body, opts), opts)
    |> HTTPClient.collect_sse(body, opts, &ResponseDecoder.chat_completions_stream_response(&1, opts))
  end

  @doc """
  Sends a streaming request and returns typed event envelopes. Consume once and handle terminal errors.
  """
  @spec chat_completions_stream_typed_events(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(chat_endpoint(client, body, opts), opts)
    |> typed_stream(
      body,
      Keyword.put(opts, :parser_finalizer, &finish_chat_typed_events/1),
      &deepseek_chat_typed_events/2
    )
  end

  @doc """
  Sends a native JSON request and returns the decoded provider payload or a tagged HTTP/transport error.
  """
  @spec responses(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def responses(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.responses_endpoint, opts)
    |> HTTPClient.post_json(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @doc """
  Sends a streaming request and returns text deltas. Consume the returned enumerable to execute streaming work.
  """
  @spec responses_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.responses_endpoint, opts) |> stream(body, opts, &OpenAIStreaming.text_deltas/1)

  @doc """
  Collects the streaming provider response into its final decoded native payload, or returns an error.
  """
  @spec responses_stream_response(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def responses_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.responses_endpoint, opts)
    |> HTTPClient.collect_sse(body, opts, &ResponseDecoder.responses_stream_response(&1, opts))
  end

  @doc """
  Returns the endpoint's streaming lifecycle events; use the typed model facade for a portable event contract.
  """
  @spec responses_stream_events(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.responses_endpoint, opts) |> stream(body, opts, &OpenAIStreaming.lifecycle_events/1)

  @doc """
  Sends a streaming request and returns typed event envelopes. Consume once and handle terminal errors.
  """
  @spec responses_stream_typed_events(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.responses_endpoint, opts) |> typed_stream(body, opts, &deepseek_responses_typed_events/1)

  @doc """
  Sends a native JSON request and returns the decoded provider payload or a tagged HTTP/transport error.
  """
  @spec completions(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def completions(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.completions_endpoint, opts)
    |> HTTPClient.post_json(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @doc """
  Sends a streaming request and returns text deltas. Consume the returned enumerable to execute streaming work.
  """
  @spec completions_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def completions_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.completions_endpoint, opts) |> stream(body, opts, &OpenAIStreaming.text_deltas/1)

  @doc """
  Collects the streaming provider response into its final decoded native payload, or returns an error.
  """
  @spec completions_stream_response(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def completions_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.completions_endpoint, opts)
    |> HTTPClient.collect_sse(body, opts, &ResponseDecoder.completions_stream_response(&1, opts))
  end

  @doc """
  Lists provider model data; this does not execute inference or alter local profiles.
  """
  @spec models(t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def models(%__MODULE__{} = client, opts \\ []),
    do: client |> http(client.models_endpoint, opts) |> HTTPClient.get(opts) |> ResponseDecoder.json(opts)

  @doc """
  Reads native account balance data with the configured credentials.
  """
  @spec balance(t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def balance(%__MODULE__{} = client, opts \\ []),
    do: client |> http(client.balance_endpoint, opts) |> HTTPClient.get(opts) |> ResponseDecoder.json(opts)

  @doc """
  Sends a native JSON request and returns the decoded provider payload or a tagged HTTP/transport error.
  """
  @spec anthropic_messages(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def anthropic_messages(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> anthropic_http(opts)
    |> HTTPClient.post_json(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @doc """
  Sends a streaming request and returns text deltas. Consume the returned enumerable to execute streaming work.
  """
  @spec anthropic_messages_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def anthropic_messages_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> anthropic_http(opts) |> stream(body, opts, &AnthropicStreaming.text_deltas/1)

  @doc """
  Collects the streaming provider response into its final decoded native payload, or returns an error.
  """
  @spec anthropic_messages_stream_response(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def anthropic_messages_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> anthropic_http(opts)
    |> HTTPClient.collect_sse(body, opts, &ResponseDecoder.anthropic_stream_response(&1, opts))
  end

  @doc """
  Returns the endpoint's streaming lifecycle events; use the typed model facade for a portable event contract.
  """
  @spec anthropic_messages_stream_events(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def anthropic_messages_stream_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> anthropic_http(opts) |> stream(body, opts, &AnthropicStreaming.lifecycle_events/1)

  @doc """
  Sends a streaming request and returns typed event envelopes. Consume once and handle terminal errors.
  """
  @spec anthropic_messages_stream_typed_events(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def anthropic_messages_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> anthropic_http(opts) |> typed_stream(body, opts, &deepseek_anthropic_typed_events/2)

  @doc "Returns a normalized endpoint for a base URL and path."
  @spec endpoint(String.t(), String.t()) :: String.t()
  def endpoint(base_url, path), do: Compat.endpoint(base_url, path)

  defp stream(http, body, opts, parser),
    do: HTTPClient.stream_sse(http, body, opts, parser, &ResponseDecoder.stream_error(&1, opts))

  defp typed_stream(http, body, opts, parser),
    do: HTTPClient.stream_typed_sse(http, body, opts, parser, &ResponseDecoder.stream_error(&1, opts))

  defp http(client, endpoint, opts),
    do: Compat.http(:deepseek, client, endpoint, opts, [Compat.user_agent(opts, "beam_weaver-deepseek/0.1")])

  defp anthropic_http(client, opts) do
    headers = [
      {"anthropic-version", Keyword.get(opts, :anthropic_version, "2023-06-01")},
      Compat.user_agent(opts, "beam_weaver-deepseek/0.1")
    ]

    http = Compat.http(:deepseek, client, client.anthropic_messages_endpoint, opts, headers)
    %{http | auth_header: "x-api-key", auth_prefix: nil}
  end

  defp chat_endpoint(client, body, opts) do
    if Keyword.get(opts, :beta, false) or prefix_request?(body) or strict_tools?(body),
      do: client.beta_chat_completions_endpoint,
      else: client.chat_completions_endpoint
  end

  defp prefix_request?(body) do
    body
    |> field("messages", [])
    |> List.wrap()
    |> Enum.any?(fn message ->
      field(message, "role") == "assistant" and field(message, "prefix") == true
    end)
  end

  defp strict_tools?(body) do
    body
    |> field("tools", [])
    |> List.wrap()
    |> Enum.any?(fn tool ->
      field(tool, "strict") == true or field(field(tool, "function", %{}), "strict") == true
    end)
  end

  defp field(map, name, default \\ nil)

  defp field(map, name, default) when is_map(map) do
    Map.get(map, name, Map.get(map, String.to_atom(name), default))
  end

  defp field(_value, _name, default), do: default

  defp api_root(base_url) do
    base_url = String.trim_trailing(base_url, "/")

    case Enum.find(["/v1", "/beta", "/anthropic"], &String.ends_with?(base_url, &1)) do
      nil -> base_url
      suffix -> base_url |> String.replace_suffix(suffix, "") |> api_root()
    end
  end

  # Parses a batch of a live Chat Completions stream, holding its `Done`
  # events back for the complete reply that ends the stream.
  defp deepseek_chat_typed_events(events, state) do
    events
    |> OpenAICompatibleStreaming.typed_events(%{
      provider: :deepseek,
      choice_usage: false,
      include_chunk_id: true,
      reasoning_index: 0,
      unknown_delta_key: :deepseek_delta
    })
    |> OpenAICompatibleStreaming.hold_events(events, state)
  end

  # Ends a live Chat Completions stream with the complete reply: the response
  # the stream's events add up to, decoded like a non-streamed one. A stream
  # without choices has no reply.
  defp finish_chat_typed_events(state) do
    OpenAICompatibleStreaming.finish_typed_events(state, :deepseek, fn events ->
      case events |> ResponseDecoder.reduce_chat_events(nil) |> ResponseDecoder.chat_stream_response() do
        {:ok, response} -> BeamWeaver.DeepSeek.Messages.chat_response_to_message(response)
        {:error, _error} -> :none
      end
    end)
  end

  defp deepseek_responses_typed_events(events) do
    events
    |> BeamWeaver.OpenAI.Streaming.typed_events()
    |> Enum.map(fn
      %BeamWeaver.Stream.Envelope{event: %BeamWeaver.Stream.Events.Message{message: message}} = envelope ->
        response = message.response_metadata.raw_provider_response

        case BeamWeaver.DeepSeek.Messages.responses_to_message(response) do
          {:ok, message} -> %{envelope | event: %BeamWeaver.Stream.Events.Message{message: message}}
          {:error, error} -> %{envelope | event: %BeamWeaver.Stream.Events.Error{error: error}}
        end

      envelope ->
        envelope
    end)
    |> Enum.map(&put_deepseek_provider/1)
  end

  defp deepseek_anthropic_typed_events(events, state) do
    {events, state} = BeamWeaver.Anthropic.Streaming.typed_events(events, state)
    {Enum.map(events, &put_deepseek_provider/1), state}
  end

  defp put_deepseek_provider(%BeamWeaver.Stream.Envelope{} = envelope) do
    %{envelope | metadata: Map.put(envelope.metadata || %{}, :provider, :deepseek)}
  end
end
