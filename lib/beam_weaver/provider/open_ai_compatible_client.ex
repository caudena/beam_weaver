defmodule BeamWeaver.Provider.OpenAICompatibleClient do
  @moduledoc false

  alias BeamWeaver.Provider.HTTPClient

  @doc false
  def endpoint(base_url, path) do
    String.trim_trailing(to_string(base_url), "/") <> "/" <> String.trim_leading(path, "/")
  end

  @doc false
  def chat_completions_endpoint(%{chat_completions_endpoint: endpoint}, _fallback) do
    endpoint
  end

  def chat_completions_endpoint(opts, fallback) when is_list(opts) and is_function(fallback, 1) do
    Keyword.get(opts, :chat_completions_endpoint, fallback.(opts))
  end

  @doc false
  def normalize_client(%_{} = client, opts, _new_fun, fields) when is_list(opts) do
    override_client(client, opts, fields)
  end

  def normalize_client(opts, overrides, new_fun, fields)
      when is_list(opts) and is_list(overrides) and is_function(new_fun, 1) do
    opts
    |> new_fun.()
    |> override_client(overrides, fields)
  end

  @doc false
  def override_client(client, opts, fields) when is_list(opts) and is_list(fields) do
    Enum.reduce(fields, client, fn field, acc ->
      case Keyword.fetch(opts, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  @doc false
  def request(client, body, opts, http_client)
      when is_map(body) and is_function(http_client, 2) do
    client
    |> http_client.(opts)
    |> HTTPClient.request(body, opts)
  end

  @doc false
  def post_json(client, body, opts, http_client)
      when is_map(body) and is_function(http_client, 2) do
    client
    |> http_client.(opts)
    |> HTTPClient.post_json(body, opts)
  end

  @doc false
  def get(client, opts, http_client) when is_function(http_client, 2) do
    client
    |> http_client.(opts)
    |> HTTPClient.get(opts)
  end

  @doc false
  def stream_sse(client, body, opts, http_client, parser, error_decoder)
      when is_map(body) and is_function(http_client, 2) do
    client
    |> http_client.(opts)
    |> HTTPClient.stream_sse(body, opts, parser, error_decoder)
  end

  @doc false
  def collect_sse(client, body, opts, http_client, decoder)
      when is_map(body) and is_function(http_client, 2) do
    client
    |> http_client.(opts)
    |> HTTPClient.collect_sse(body, opts, decoder)
  end

  @doc false
  def http_client(provider, client, opts, overrides \\ []) do
    %HTTPClient{
      provider: provider,
      endpoint: Keyword.get(opts, :endpoint, Map.fetch!(client, :endpoint)),
      api_key: Keyword.get(opts, :api_key, Map.get(client, :api_key)),
      auth_header: Keyword.get(overrides, :auth_header, "authorization"),
      auth_prefix: Keyword.get(overrides, :auth_prefix, "Bearer"),
      default_headers: Keyword.get(overrides, :default_headers, default_headers(client)),
      transport: Keyword.get(opts, :transport, Map.get(client, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, Map.get(client, :transport_opts, [])),
      timeout: Keyword.get(opts, :timeout, Map.get(client, :timeout, 15_000))
    }
  end

  defp default_headers(client), do: Map.get(client, :default_headers, [])
end
