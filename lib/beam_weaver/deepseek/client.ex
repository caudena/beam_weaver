defmodule BeamWeaver.DeepSeek.Client do
  @moduledoc """
  Raw client for DeepSeek's native, OpenAI-compatible, and Anthropic-compatible APIs.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.DeepSeek.Client.ResponseDecoder
  alias BeamWeaver.DeepSeek.Error
  alias BeamWeaver.Provider.OpenAICompatibleClient
  alias BeamWeaver.Provider.OpenAICompatibleStreaming
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Transport.Request

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

  @client_fields [
    :base_url,
    :beta_base_url,
    :anthropic_base_url,
    :endpoint,
    :chat_completions_endpoint,
    :beta_chat_completions_endpoint,
    :responses_endpoint,
    :completions_endpoint,
    :models_endpoint,
    :balance_endpoint,
    :anthropic_messages_endpoint,
    :api_key,
    :default_headers,
    :transport,
    :transport_opts,
    :timeout
  ]

  @doc "Builds a DeepSeek client from keyword options or a map."
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    configured_base_url = configured_url(opts, :base_url, [:deepseek, :base_url], @default_base_url)
    api_root = api_root(configured_base_url)
    base_url = stable_base_url(configured_base_url, api_root)

    beta_base_url =
      configured_url(opts, :beta_base_url, [:deepseek, :beta_base_url], endpoint(api_root, "beta"))

    anthropic_base_url =
      configured_url(
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
        Keyword.has_key?(opts, :beta_chat_completions_endpoint) ->
          Keyword.fetch!(opts, :beta_chat_completions_endpoint)

        (Keyword.has_key?(opts, :chat_completions_endpoint) or
           Keyword.has_key?(opts, :endpoint)) and
            chat_completions_endpoint != default_chat_endpoint ->
          chat_completions_endpoint

        true ->
          endpoint(beta_base_url, "chat/completions")
      end

    struct(__MODULE__,
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
    )
  end

  @spec chat_completions(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def chat_completions(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, chat_completions_endpoint(client, body, opts))

    client
    |> do_request(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @spec chat_completions_stream(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, chat_completions_endpoint(client, body, opts))

    do_stream(client, body, opts, &OpenAICompatibleStreaming.text_deltas/1)
  end

  @spec chat_completions_stream_response(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def chat_completions_stream_response(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, chat_completions_endpoint(client, body, opts))

    do_stream_collect(client, body, opts, &ResponseDecoder.chat_completions_stream_response(&1, opts))
  end

  @spec chat_completions_stream_typed_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream_typed_events(client_or_opts, body, opts \\ [])
      when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, chat_completions_endpoint(client, body, opts))

    do_stream(client, body, opts, &deepseek_chat_typed_events/1)
  end

  @spec responses(t() | keyword(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def responses(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.responses_endpoint)

    client
    |> do_request(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @spec responses_stream(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.responses_endpoint)

    do_stream(client, body, opts, &BeamWeaver.OpenAI.Streaming.text_deltas/1)
  end

  @spec responses_stream_response(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def responses_stream_response(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.responses_endpoint)

    do_stream_collect(client, body, opts, &ResponseDecoder.responses_stream_response(&1, opts))
  end

  @spec responses_stream_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_events(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.responses_endpoint)

    do_stream(client, body, opts, &BeamWeaver.OpenAI.Streaming.lifecycle_events/1)
  end

  @spec responses_stream_typed_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_typed_events(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.responses_endpoint)

    do_stream(client, body, opts, &deepseek_responses_typed_events/1)
  end

  @spec completions(t() | keyword(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def completions(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.completions_endpoint)

    client
    |> do_request(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @spec completions_stream(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def completions_stream(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.completions_endpoint)

    do_stream(client, body, opts, &BeamWeaver.OpenAI.Streaming.text_deltas/1)
  end

  @spec completions_stream_response(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def completions_stream_response(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.completions_endpoint)

    do_stream_collect(client, body, opts, &ResponseDecoder.completions_stream_response(&1, opts))
  end

  @spec models(t() | keyword(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def models(client_or_opts, opts \\ []) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.models_endpoint)

    client
    |> do_get(opts)
    |> ResponseDecoder.json(opts)
  end

  @spec balance(t() | keyword(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def balance(client_or_opts, opts \\ []) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.balance_endpoint)

    client
    |> do_get(opts)
    |> ResponseDecoder.json(opts)
  end

  @spec anthropic_messages(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def anthropic_messages(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.anthropic_messages_endpoint)

    client
    |> do_request(body, opts, :anthropic)
    |> ResponseDecoder.json(opts)
  end

  @spec anthropic_messages_stream(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def anthropic_messages_stream(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.anthropic_messages_endpoint)

    do_stream(client, body, opts, &BeamWeaver.Anthropic.Streaming.text_deltas/1, :anthropic)
  end

  @spec anthropic_messages_stream_response(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def anthropic_messages_stream_response(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.anthropic_messages_endpoint)

    do_stream_collect(
      client,
      body,
      opts,
      &ResponseDecoder.anthropic_stream_response(&1, opts),
      :anthropic
    )
  end

  @spec anthropic_messages_stream_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def anthropic_messages_stream_events(client_or_opts, body, opts \\ []) when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.anthropic_messages_endpoint)

    do_stream(client, body, opts, &BeamWeaver.Anthropic.Streaming.lifecycle_events/1, :anthropic)
  end

  @spec anthropic_messages_stream_typed_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def anthropic_messages_stream_typed_events(client_or_opts, body, opts \\ [])
      when is_map(body) do
    client = normalize_client(client_or_opts, opts)
    opts = with_endpoint(opts, client.anthropic_messages_endpoint)

    do_stream(client, body, opts, &deepseek_anthropic_typed_events/2, :anthropic)
  end

  @doc false
  @spec request(t(), map(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    OpenAICompatibleClient.request(client, body, opts, &http_client/2)
  end

  @doc "Returns a normalized endpoint for a base URL and path."
  @spec endpoint(String.t(), String.t()) :: String.t()
  def endpoint(base_url, path), do: OpenAICompatibleClient.endpoint(base_url, path)

  defp do_request(client, body, opts, auth \\ :bearer) do
    OpenAICompatibleClient.post_json(client, body, opts, &http_client(&1, &2, auth))
  end

  defp do_get(client, opts) do
    OpenAICompatibleClient.get(client, opts, &http_client/2)
  end

  defp do_stream(client, body, opts, parser, auth \\ :bearer) do
    OpenAICompatibleClient.stream_sse(
      client,
      body,
      opts,
      &http_client(&1, &2, auth),
      parser,
      &ResponseDecoder.stream_error(&1, opts)
    )
  end

  defp do_stream_collect(client, body, opts, decoder, auth \\ :bearer) do
    OpenAICompatibleClient.collect_sse(
      client,
      body,
      opts,
      &http_client(&1, &2, auth),
      decoder
    )
  end

  defp http_client(client, opts), do: http_client(client, opts, :bearer)

  defp http_client(client, opts, :bearer) do
    OpenAICompatibleClient.http_client(:deepseek, client, opts,
      auth_header: "authorization",
      auth_prefix: "Bearer",
      default_headers: default_headers(client, opts)
    )
  end

  defp http_client(client, opts, :anthropic) do
    OpenAICompatibleClient.http_client(:deepseek, client, opts,
      auth_header: "x-api-key",
      auth_prefix: nil,
      default_headers: anthropic_headers(client, opts)
    )
  end

  defp default_headers(client, opts) do
    [{"user-agent", Keyword.get(opts, :user_agent, "beam_weaver-deepseek/0.1")}]
    |> Kernel.++(Request.normalize_headers(client.default_headers))
  end

  defp anthropic_headers(client, opts) do
    [{"anthropic-version", Keyword.get(opts, :anthropic_version, "2023-06-01")}]
    |> Kernel.++(default_headers(client, opts))
  end

  defp normalize_client(client_or_opts, opts) do
    OpenAICompatibleClient.normalize_client(client_or_opts, opts, &new/1, @client_fields)
  end

  defp chat_completions_endpoint(client, body, opts) do
    cond do
      Keyword.has_key?(opts, :endpoint) -> Keyword.fetch!(opts, :endpoint)
      Keyword.get(opts, :beta, false) -> client.beta_chat_completions_endpoint
      beta_chat_request?(body) -> client.beta_chat_completions_endpoint
      true -> client.chat_completions_endpoint
    end
  end

  defp beta_chat_request?(body), do: prefix_request?(body) or strict_tools?(body)

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

  defp with_endpoint(opts, fallback) do
    Keyword.put_new(opts, :endpoint, fallback)
  end

  defp configured_url(opts, key, config_path, default) do
    if Keyword.has_key?(opts, key) do
      Keyword.fetch!(opts, key) || default
    else
      Config.get(config_path, default)
    end
  end

  defp api_root(base_url) do
    base_url = base_url |> to_string() |> String.trim_trailing("/")

    case Enum.find(["/v1", "/beta", "/anthropic"], &String.ends_with?(base_url, &1)) do
      nil -> base_url
      suffix -> base_url |> strip_api_suffix(suffix) |> api_root()
    end
  end

  defp stable_base_url(base_url, api_root) do
    base_url = base_url |> to_string() |> String.trim_trailing("/")

    if String.ends_with?(base_url, "/beta") or String.ends_with?(base_url, "/anthropic") do
      api_root
    else
      base_url
    end
  end

  defp strip_api_suffix(base_url, suffix) do
    if String.ends_with?(base_url, suffix) do
      String.slice(base_url, 0, byte_size(base_url) - byte_size(suffix))
    else
      base_url
    end
  end

  defp deepseek_chat_typed_events(events) do
    OpenAICompatibleStreaming.typed_events(events, %{
      provider: :deepseek,
      provider_name: "DeepSeek",
      error_module: Error,
      usage_metadata: &BeamWeaver.OpenAI.ChatCompletions.Messages.Response.usage_metadata/1,
      stream_metadata: &empty_stream_metadata/3,
      choice_usage: false,
      include_chunk_id: true,
      reasoning_index: 0,
      unknown_delta_key: :deepseek_delta
    })
  end

  defp deepseek_responses_typed_events(events) do
    events
    |> BeamWeaver.OpenAI.Streaming.typed_events()
    |> Enum.map(&put_deepseek_provider/1)
  end

  defp empty_stream_metadata(_events, _message, _opts), do: %{}

  defp deepseek_anthropic_typed_events(events, state) do
    {events, state} = BeamWeaver.Anthropic.Streaming.typed_events(events, state)
    {Enum.map(events, &put_deepseek_provider/1), state}
  end

  defp put_deepseek_provider(%BeamWeaver.Stream.Envelope{} = envelope) do
    %{envelope | metadata: Map.put(envelope.metadata || %{}, :provider, :deepseek)}
  end

  defp put_deepseek_provider(event), do: event
end

defimpl Inspect, for: BeamWeaver.DeepSeek.Client do
  def inspect(struct, opts), do: BeamWeaver.Provider.RedactedInspect.redacted_struct(struct, opts)
end
