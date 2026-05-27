defmodule BeamWeaver.OpenAI.Client do
  @moduledoc """
  Small OpenAI Responses API client built on `BeamWeaver.Transport`.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.OpenAI.Client.ResponseDecoder
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.Provider.OpenAICompatibleClient
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Transport.Request

  @default_base_url "https://api.openai.com/v1"
  @default_endpoint @default_base_url <> "/responses"
  @default_timeout 15_000

  defstruct endpoint: @default_endpoint,
            api_key: nil,
            organization: nil,
            project: nil,
            transport: nil,
            transport_opts: [],
            timeout: @default_timeout

  @type t :: %__MODULE__{
          endpoint: String.t(),
          api_key: String.t() | (-> String.t() | nil) | nil,
          organization: String.t() | nil,
          project: String.t() | nil,
          transport: module(),
          transport_opts: keyword(),
          timeout: non_neg_integer()
        }

  @doc """
  Builds a client from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__,
      endpoint: Keyword.get(opts, :endpoint, @default_endpoint),
      api_key: Config.option(opts, :api_key, [:openai, :api_key]),
      organization: Config.option(opts, :organization, [:openai, :organization]),
      project: Config.option(opts, :project, [:openai, :project]),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    )
  end

  @doc """
  Posts a JSON body to the Responses API and decodes a JSON response body.
  """
  @spec responses(t() | keyword(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def responses(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_request(body, opts)
    |> ResponseDecoder.json(opts)
  end

  @doc """
  Posts a JSON body and decodes a JSON response body.
  """
  @spec post_json(t() | keyword(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def post_json(client_or_opts, endpoint, body, opts \\ [])
      when is_binary(endpoint) and is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_request(body, Keyword.put(opts, :endpoint, endpoint))
    |> ResponseDecoder.json(opts)
  end

  @doc """
  Posts a streaming JSON body and returns parsed text deltas.
  """
  @spec post_stream(t() | keyword(), String.t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def post_stream(client_or_opts, endpoint, body, opts \\ [])
      when is_binary(endpoint) and is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_stream(
      body,
      Keyword.put(opts, :endpoint, endpoint),
      &BeamWeaver.OpenAI.Streaming.text_deltas/1,
      &ResponseDecoder.text_stream/1
    )
  end

  @doc """
  Posts a streaming Responses API body and returns parsed text deltas.
  """
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

  @doc """
  Posts a streaming Responses API body and reconstructs the final JSON response.
  """
  @spec responses_stream_response(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def responses_stream_response(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(opts)
    |> do_stream_collect(body, opts, &ResponseDecoder.responses_stream_map(&1, opts))
  end

  @doc """
  Posts a streaming Responses API body and returns content-block lifecycle events.
  """
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

  @doc """
  Posts a streaming Responses API body and returns typed BeamWeaver stream envelopes.
  """
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

  @doc """
  Posts a JSON body to the Chat Completions API and decodes a JSON response body.
  """
  @spec chat_completions(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def chat_completions(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(Keyword.put(opts, :endpoint, endpoint("chat/completions")))
    |> do_request(body, Keyword.put(opts, :endpoint, endpoint("chat/completions")))
    |> ResponseDecoder.json(opts)
  end

  @doc """
  Posts a streaming Chat Completions body and returns parsed text deltas.
  """
  @spec chat_completions_stream(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(Keyword.put(opts, :endpoint, endpoint("chat/completions")))
    |> do_stream(
      body,
      Keyword.put(opts, :endpoint, endpoint("chat/completions")),
      &BeamWeaver.OpenAI.Streaming.text_deltas/1,
      &ResponseDecoder.text_stream/1
    )
  end

  @doc """
  Posts a streaming Chat Completions body and reconstructs the final JSON response.
  """
  @spec chat_completions_stream_response(t() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def chat_completions_stream_response(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(Keyword.put(opts, :endpoint, endpoint("chat/completions")))
    |> do_stream_collect(
      body,
      Keyword.put(opts, :endpoint, endpoint("chat/completions")),
      &ResponseDecoder.chat_completions_stream_response(&1, opts)
    )
  end

  @doc """
  Posts a streaming Chat Completions body and returns typed BeamWeaver stream envelopes.
  """
  @spec chat_completions_stream_typed_events(t() | keyword(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def chat_completions_stream_typed_events(client_or_opts, body, opts \\ []) when is_map(body) do
    client_or_opts
    |> normalize_client(Keyword.put(opts, :endpoint, endpoint("chat/completions")))
    |> do_stream(
      body,
      Keyword.put(opts, :endpoint, endpoint("chat/completions")),
      &BeamWeaver.OpenAI.Streaming.typed_events/1,
      &ResponseDecoder.typed_events/1
    )
  end

  @doc """
  Retrieves a Responses API response.
  """
  def retrieve_response(client_or_opts, response_id, opts \\ []) when is_binary(response_id) do
    endpoint = endpoint("responses/#{response_id}")

    client_or_opts
    |> normalize_client(Keyword.put(opts, :endpoint, endpoint))
    |> do_get(Keyword.put(opts, :endpoint, endpoint))
    |> ResponseDecoder.json(opts)
  end

  @doc """
  Lists input items for a Responses API response.
  """
  def list_response_input_items(client_or_opts, response_id, opts \\ [])
      when is_binary(response_id) do
    endpoint = endpoint("responses/#{response_id}/input_items")

    client_or_opts
    |> normalize_client(Keyword.put(opts, :endpoint, endpoint))
    |> do_get(Keyword.put(opts, :endpoint, endpoint))
    |> ResponseDecoder.json(opts)
  end

  @doc """
  Compacts a Responses API response when the provider supports it.
  """
  def compact_response(client_or_opts, response_id, body \\ %{}, opts \\ [])
      when is_binary(response_id) and is_map(body) do
    endpoint = endpoint("responses/#{response_id}/compact")

    client_or_opts
    |> normalize_client(Keyword.put(opts, :endpoint, endpoint))
    |> do_request(body, Keyword.put(opts, :endpoint, endpoint))
    |> ResponseDecoder.json(opts)
  end

  @doc false
  @spec request(t(), map(), keyword()) :: Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    OpenAICompatibleClient.request(client, body, opts, &http_client/2)
  end

  @doc """
  Returns the default OpenAI API endpoint for a path.
  """
  @spec endpoint(String.t()) :: String.t()
  def endpoint(path) when is_binary(path) do
    OpenAICompatibleClient.endpoint(@default_base_url, path)
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

  defp normalize_client(client_or_opts, opts),
    do:
      OpenAICompatibleClient.normalize_client(client_or_opts, opts, &new/1, [
        :endpoint,
        :api_key,
        :organization,
        :project,
        :transport,
        :transport_opts,
        :timeout
      ])

  defp http_client(%__MODULE__{} = client, opts) do
    OpenAICompatibleClient.http_client(:openai, client, opts,
      auth_header: "authorization",
      auth_prefix: "Bearer",
      default_headers: headers(client)
    )
  end

  defp headers(%__MODULE__{} = client) do
    []
    |> maybe_put_header("openai-organization", client.organization)
    |> maybe_put_header("openai-project", client.project)
  end

  defp maybe_put_header(headers, _name, nil), do: headers
  defp maybe_put_header(headers, _name, ""), do: headers
  defp maybe_put_header(headers, name, value), do: [{name, value} | headers]
end
