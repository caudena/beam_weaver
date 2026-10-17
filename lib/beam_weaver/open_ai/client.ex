defmodule BeamWeaver.OpenAI.Client do
  @moduledoc """
  Small OpenAI Responses API client built on `BeamWeaver.Transport`.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.Client.ResponseDecoder
  alias BeamWeaver.OpenAI.Streaming
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Provider.OpenAICompatibleStreaming
  alias BeamWeaver.Provider.Options, as: ProviderOptions

  @default_base_url "https://api.openai.com/v1"
  @default_timeout 15_000

  defstruct base_url: @default_base_url,
            endpoint: @default_base_url <> "/responses",
            chat_completions_endpoint: @default_base_url <> "/chat/completions",
            api_key: nil,
            organization: nil,
            project: nil,
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: @default_timeout

  @type t :: %__MODULE__{
          base_url: String.t(),
          endpoint: String.t(),
          chat_completions_endpoint: String.t(),
          api_key: String.t() | (-> String.t() | nil) | nil,
          organization: String.t() | nil,
          project: String.t() | nil,
          default_headers: [{String.t(), String.t()}],
          transport: module(),
          transport_opts: keyword(),
          timeout: non_neg_integer()
        }

  @doc """
  Builds a client from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_url = Compat.configured_url(opts, :base_url, [:openai, :base_url], @default_base_url)

    %__MODULE__{
      base_url: base_url,
      endpoint: Keyword.get(opts, :endpoint, endpoint(base_url, "responses")),
      chat_completions_endpoint: Keyword.get(opts, :chat_completions_endpoint, endpoint(base_url, "chat/completions")),
      api_key: Config.option(opts, :api_key, [:openai, :api_key]),
      organization: Config.option(opts, :organization, [:openai, :organization]),
      project: Config.option(opts, :project, [:openai, :project]),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  @doc """
  Posts a JSON body to the Responses API and decodes a JSON response body.
  """
  @spec responses(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def responses(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> post(body, opts)

  @doc """
  Posts a JSON body and decodes a JSON response body.
  """
  @spec post_json(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def post_json(%__MODULE__{} = client, endpoint, body, opts \\ []) when is_binary(endpoint) and is_map(body),
    do: client |> http(endpoint, opts) |> post(body, Keyword.put(opts, :endpoint, endpoint))

  @doc """
  Posts a streaming JSON body and returns parsed text deltas.
  """
  @spec post_stream(t(), String.t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def post_stream(%__MODULE__{} = client, endpoint, body, opts \\ []) when is_binary(endpoint) and is_map(body),
    do: client |> http(endpoint, opts) |> stream_text(body, Keyword.put(opts, :endpoint, endpoint))

  @doc """
  Posts a streaming Responses API body and returns parsed text deltas.
  """
  @spec responses_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> stream_text(body, opts)

  @doc """
  Posts a streaming Responses API body and reconstructs the final JSON response.
  """
  @spec responses_stream_response(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def responses_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> collect_response(body, opts)

  @doc """
  Posts a streaming Responses API body and returns content-block lifecycle events.
  """
  @spec responses_stream_events(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.endpoint, opts) |> stream_lifecycle(body, opts)

  @doc """
  Posts a streaming Responses API body and returns typed BeamWeaver stream envelopes.
  """
  @spec responses_stream_typed_events(t(), map() | binary(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def responses_stream_typed_events(%__MODULE__{} = client, body, opts \\ [])
      when is_map(body) or is_binary(body),
      do: client |> http(client.endpoint, opts) |> stream_typed(body, opts)

  @doc """
  Posts a JSON body to the Chat Completions API and decodes a JSON response body.
  """
  @spec chat_completions(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def chat_completions(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.chat_completions_endpoint, opts) |> post(body, opts)

  @doc """
  Posts a streaming Chat Completions body and returns parsed text deltas.
  """
  @spec chat_completions_stream(t(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.chat_completions_endpoint, opts) |> stream_text(body, opts)

  @doc """
  Posts a streaming Chat Completions body and reconstructs the final JSON response.
  """
  @spec chat_completions_stream_response(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def chat_completions_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.chat_completions_endpoint, opts) |> collect_chat_completion(body, opts)

  @doc """
  Posts a streaming Chat Completions body and returns typed BeamWeaver stream envelopes.

  The stream ends with the complete reply, decoded like a reply from
  `chat_completions/3`, followed by its `Done` events.
  """
  @spec chat_completions_stream_typed_events(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: client |> http(client.chat_completions_endpoint, opts) |> stream_chat_completion(body, opts)

  @doc """
  Retrieves a Responses API response.
  """
  def retrieve_response(%__MODULE__{} = client, response_id, opts \\ []) when is_binary(response_id) do
    client
    |> http(endpoint(client, "responses/#{response_id}"), opts)
    |> HTTPClient.get(opts)
    |> ResponseDecoder.json(opts, ResponseDecoder.config())
  end

  @doc """
  Lists input items for a Responses API response.
  """
  def list_response_input_items(%__MODULE__{} = client, response_id, opts \\ []) when is_binary(response_id) do
    client
    |> http(endpoint(client, "responses/#{response_id}/input_items"), opts)
    |> HTTPClient.get(opts)
    |> ResponseDecoder.json(opts, ResponseDecoder.config())
  end

  @doc """
  Compacts a Responses API response when the provider supports it.
  """
  def compact_response(%__MODULE__{} = client, response_id, body \\ %{}, opts \\ [])
      when is_binary(response_id) and is_map(body),
      do: client |> http(endpoint(client, "responses/#{response_id}/compact"), opts) |> post(body, opts)

  @doc """
  Returns the OpenAI API URL for `path` under a client's (or a raw) base URL.
  """
  @spec endpoint(t() | String.t(), String.t()) :: String.t()
  def endpoint(%__MODULE__{base_url: base_url}, path), do: endpoint(base_url, path)
  def endpoint(base_url, path) when is_binary(path), do: Compat.endpoint(base_url, path)

  @doc false
  def post(http, body, opts, config \\ ResponseDecoder.config()),
    do: http |> HTTPClient.post_json(body, opts) |> ResponseDecoder.json(opts, config)

  @doc false
  def stream_text(http, body, opts, config \\ ResponseDecoder.config(), parser \\ &Streaming.text_deltas/1),
    do: HTTPClient.stream_sse(http, body, opts, parser, &ResponseDecoder.stream_error(&1, config))

  @doc false
  def collect_response(http, body, opts, config \\ ResponseDecoder.config()),
    do: HTTPClient.collect_sse(http, body, opts, &ResponseDecoder.responses_stream_map(&1, opts, config))

  @doc false
  def stream_lifecycle(http, body, opts, config \\ ResponseDecoder.config()),
    do:
      HTTPClient.stream_sse(http, body, opts, &Streaming.lifecycle_events/1, &ResponseDecoder.stream_error(&1, config))

  @doc false
  def stream_typed(http, body, opts, config \\ ResponseDecoder.config(), parser \\ &Streaming.typed_events/1),
    do: HTTPClient.stream_typed_sse(http, body, opts, parser, &ResponseDecoder.stream_error(&1, config))

  @doc false
  def collect_chat_completion(http, body, opts, config \\ ResponseDecoder.config()) do
    HTTPClient.collect_sse(http, body, opts, &ResponseDecoder.chat_completions_stream_response(&1, opts, config))
  end

  @doc false
  def stream_chat_completion(
        http,
        body,
        opts,
        config \\ ResponseDecoder.config(),
        decode \\ &ChatCompletions.Messages.response_to_message/1
      ) do
    finish = &ResponseDecoder.finish_chat_completions_typed_events(&1, &2, opts, config, decode)

    HTTPClient.stream_typed_sse(
      http,
      body,
      Keyword.put(opts, :parser_finalizer, finish),
      &chat_completions_typed_events/2,
      &ResponseDecoder.stream_error(&1, config)
    )
  end

  @doc false
  def collect_chat_message(http, body, opts, config),
    do: HTTPClient.collect_sse(http, body, opts, &ResponseDecoder.chat_message(&1, opts, config))

  @doc false
  def stream_chat_message(http, body, opts, config) do
    finish = &ResponseDecoder.finish_chat_message_events(&1, &2, opts, config)

    HTTPClient.stream_typed_sse(
      http,
      body,
      Keyword.put(opts, :parser_finalizer, finish),
      &OpenAICompatibleStreaming.typed_events(&1, &2, config.stream),
      &ResponseDecoder.stream_error(&1, config)
    )
  end

  # Parses a batch of a live Chat Completions stream, holding its `Done`
  # events back for the complete reply that ends the stream.
  defp chat_completions_typed_events(events, state),
    do: events |> Streaming.typed_events() |> OpenAICompatibleStreaming.hold_events(events, state)

  defp http(client, endpoint, opts) do
    headers =
      for {name, value} <- [{"openai-project", client.project}, {"openai-organization", client.organization}],
          value not in [nil, ""],
          do: {name, value}

    Compat.http(:openai, client, endpoint, opts, headers)
  end
end
