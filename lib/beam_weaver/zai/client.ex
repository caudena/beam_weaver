defmodule BeamWeaver.ZAI.Client do
  @moduledoc ~S"""
  Native ZAI HTTP client using `BeamWeaver.Transport`.

  Use this layer when your application owns provider request/response shapes.
  It accepts native bodies and returns decoded provider data or tagged errors;
  the model facade supplies portable message normalization and compatibility
  checks. Transport/replay overrides do not establish live provider access.

  Configure this client's credentials for its actual endpoint. Keep raw request
  headers/bodies out of logs. Stream consumers own consumption and cancellation;
  collected-response helpers wait for completion. The [ZAI guide](providers/zai.md)
  identifies the implemented endpoints and external-resource lifetimes.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.Client, as: OpenAIClient
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Provider.OpenAICompatibleStreaming
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Request
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

  @doc """
  Builds client connection settings from explicit options and provider application configuration; makes no request.
  """
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

  @doc """
  Sends a native JSON request and returns the decoded provider payload or a tagged HTTP/transport error.
  """
  @spec chat_completions(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def chat_completions(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.chat_completions_endpoint, opts) |> OpenAIClient.post(body, opts, decoder())

  @doc """
  Sends a streaming request and returns text deltas. Consume the returned enumerable to execute streaming work.
  """
  @spec chat_completions_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> OpenAIClient.stream_text(body, opts, decoder(), &OpenAICompatibleStreaming.text_deltas/1)
  end

  @doc """
  Collects the streaming provider response into its final decoded native payload, or returns an error.
  """
  @spec chat_completions_stream_response(t(), map(), keyword()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, Error.t()}
  def chat_completions_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> OpenAIClient.collect_chat_message(body, opts, decoder())
  end

  @doc """
  Sends a streaming request and returns typed event envelopes. Consume once and handle terminal errors.
  """
  @spec chat_completions_stream_typed_events(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> OpenAIClient.stream_chat_message(body, opts, decoder())
  end

  @doc """
  Builds the normalized transport request for inspection or explicit dispatch; does not send it.
  """
  @spec request(t(), map(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> HTTPClient.request(body, opts)

  @doc "Returns a Z.ai API endpoint for a base URL and path."
  @spec endpoint(String.t(), String.t()) :: String.t()
  def endpoint(base_url, path), do: Compat.endpoint(base_url, path)

  defp http(client, endpoint, opts),
    do: Compat.http(:zai, client, endpoint, opts, [Compat.user_agent(opts, "beam_weaver-zai/0.1")])

  defp decoder do
    %{
      provider: :zai,
      provider_name: "Z.ai",
      request_id_header: "x-log-id",
      header_fields: [x_log_id: "x-log-id"],
      header_summary: [request_id: :x_log_id],
      context_overflow?: &context_overflow?/3,
      error_type: &error_type/3,
      stream: Streaming.config()
    }
  end

  # Z.ai names each error by a business code (`"1301"`): 1301 is its content
  # filter. 1113 (no balance) and the plan and usage limits, 1308 to 1321,
  # last until the account is recharged or the limit resets hours or days
  # later, so retrying can't fix them. A reply its content filter stops
  # partway ends with the finish reason `sensitive` instead of 1301 (see
  # `StreamFailure`). Its other errors follow their HTTP status, such as
  # 1302 (a rate limit) and 1305 (an overload), both 429s.
  @quota_codes ~w(1113 1308 1309 1310 1311 1313 1314 1315 1316 1317 1318 1319 1320 1321)

  defp error_type(status, provider_error, message) do
    code = error_code(provider_error)
    error_type = ResponseDecoder.error_field(provider_error, "type")

    cond do
      quota_exhausted?(status, code, error_type, message) -> :billing_exhausted
      "content_filter" in [code, error_type] or code in ["1301", "sensitive"] -> :content_filter
      true -> nil
    end
  end

  defp quota_exhausted?(429, code, error_type, message) do
    code in ["insufficient_quota", "quota_exceeded" | @quota_codes] or
      error_type in ["insufficient_quota", "quota_exceeded"] or
      String.contains?(String.downcase(message), [
        "insufficient balance",
        "no resource package",
        "please recharge",
        "quota exceeded"
      ])
  end

  defp quota_exhausted?(_status, _code, _error_type, _message), do: false

  # 1261 is "Prompt too long".
  defp context_overflow?(400, provider_error, message) when is_binary(message) do
    normalized = String.downcase(message)

    error_code(provider_error) in ["1261", "context_length_exceeded", "prompt_too_long"] or
      String.contains?(normalized, ["context length", "token limit", "too many tokens"])
  end

  defp context_overflow?(_status, _provider_error, _message), do: false

  # Z.ai's error reference gives its codes as numbers, its responses as
  # strings.
  defp error_code(error) do
    case ResponseDecoder.error_field(error, "code") do
      code when is_integer(code) -> Integer.to_string(code)
      code -> code
    end
  end
end
