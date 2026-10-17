defmodule BeamWeaver.Moonshot.Client do
  @moduledoc """
  Moonshot OpenAI-compatible API client built on `BeamWeaver.Transport`.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Moonshot.Streaming
  alias BeamWeaver.OpenAI.Client, as: OpenAIClient
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Provider.OpenAICompatibleStreaming
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Request

  @default_base_url "https://api.moonshot.ai/v1"
  @default_timeout 15_000

  @header_fields [
    msh_context_cache_token_saved: "msh-context-cache-token-saved",
    msh_usage_cache_write_tokens_5m: "msh-usage-cache-write-tokens-5m",
    msh_usage_cache_write_tokens_1h: "msh-usage-cache-write-tokens-1h",
    msh_gid: "msh-gid",
    msh_org_id: "msh-org-id",
    msh_project_id: "msh-project-id",
    msh_request_id: "msh-request-id",
    msh_trace_mode: "msh-trace-mode",
    msh_uid: "msh-uid",
    x_msh_trace_id: "x-msh-trace-id"
  ]

  defstruct base_url: @default_base_url,
            endpoint: @default_base_url <> "/chat/completions",
            chat_completions_endpoint: @default_base_url <> "/chat/completions",
            count_tokens_endpoint: @default_base_url <> "/tokenizers/estimate-token-count",
            api_key: nil,
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: @default_timeout

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_url = Compat.configured_url(opts, :base_url, [:moonshot, :base_url], @default_base_url)
    chat_endpoint = endpoint(base_url, "chat/completions")

    %__MODULE__{
      base_url: base_url,
      endpoint: Keyword.get(opts, :endpoint, chat_endpoint),
      chat_completions_endpoint: Keyword.get(opts, :chat_completions_endpoint, chat_endpoint),
      count_tokens_endpoint:
        Keyword.get(opts, :count_tokens_endpoint, endpoint(base_url, "tokenizers/estimate-token-count")),
      api_key: Config.option(opts, :api_key, [:moonshot, :api_key]),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  @spec chat_completions(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def chat_completions(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.chat_completions_endpoint, opts) |> OpenAIClient.post(body, opts, decoder())

  @spec chat_completions_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> OpenAIClient.stream_text(body, opts, decoder(), &OpenAICompatibleStreaming.text_deltas/1)
  end

  @spec chat_completions_stream_response(t(), map(), keyword()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, Error.t()}
  def chat_completions_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> OpenAIClient.collect_chat_message(body, opts, decoder())
  end

  @spec chat_completions_stream_typed_events(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> http(client.chat_completions_endpoint, opts)
    |> OpenAIClient.stream_chat_message(body, opts, decoder())
  end

  @spec estimate_token_count(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def estimate_token_count(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.count_tokens_endpoint, opts) |> OpenAIClient.post(body, opts, decoder())

  @spec request(t(), map(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> HTTPClient.request(body, opts)

  @doc "Returns a Moonshot API endpoint for a base URL and path."
  @spec endpoint(String.t(), String.t()) :: String.t()
  def endpoint(base_url, path), do: Compat.endpoint(base_url, path)

  defp http(client, endpoint, opts),
    do: Compat.http(:moonshot, client, endpoint, opts, [Compat.user_agent(opts, "beam_weaver-moonshot/0.1")])

  defp decoder do
    %{
      provider: :moonshot,
      header_fields: @header_fields,
      header_summary: [request_id: :msh_request_id],
      context_overflow?: &context_overflow?/3,
      error_type: &error_type/3,
      stream: Streaming.config()
    }
  end

  # Kimi names the error in `type`, such as `exceeded_current_quota_error`
  # (HTTP 429 or 403, an exhausted balance or suspended account), which
  # retrying can't fix, or `content_filter` (HTTP 400). Its other errors
  # follow their HTTP status, such as `engine_overloaded_error`, a 429.
  defp error_type(_status, provider_error, _message) do
    names = [ResponseDecoder.error_field(provider_error, "code"), ResponseDecoder.error_field(provider_error, "type")]

    cond do
      "exceeded_current_quota_error" in names -> :billing_exhausted
      "content_filter" in names -> :content_filter
      true -> nil
    end
  end

  defp context_overflow?(400, provider_error, message) when is_binary(message) do
    code = ResponseDecoder.error_field(provider_error, "code")
    normalized = String.downcase(message)

    code in ["context_length_exceeded", "prompt_too_long"] or
      String.contains?(normalized, [
        "input token length too long",
        "exceeded model token limit",
        "exceeds the model specification",
        "context length",
        "too many tokens"
      ])
  end

  defp context_overflow?(_status, _provider_error, _message), do: false
end
