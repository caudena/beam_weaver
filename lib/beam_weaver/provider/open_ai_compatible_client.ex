defmodule BeamWeaver.Provider.OpenAICompatibleClient do
  @moduledoc false

  # Pieces shared by the OpenAI-compatible provider clients (OpenAI, xAI,
  # DeepSeek, Moonshot, Z.ai). A client builds one `HTTPClient` per call with
  # `http/5` and pipes it into `HTTPClient.post_json/3`, `get/2`,
  # `stream_sse/5` or `collect_sse/4`.

  alias BeamWeaver.Config
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Transport.Request

  @doc false
  def endpoint(base_url, path) do
    String.trim_trailing(to_string(base_url), "/") <> "/" <> String.trim_leading(path, "/")
  end

  @doc false
  def configured_url(opts, key, config_path, default),
    do: Keyword.get(opts, key) || Config.get(config_path, default)

  # Defaults `opts[key]` to `path` under the configured base URL.
  @doc false
  def put_endpoint(opts, key, provider, default_base_url, path) do
    Keyword.put_new_lazy(opts, key, fn ->
      opts |> configured_url(:base_url, [provider, :base_url], default_base_url) |> endpoint(path)
    end)
  end

  # Model options accept `:base_url` as shorthand: it fills each endpoint
  # option in `endpoints` (`key: path`) not given explicitly, then is dropped.
  @doc false
  def expand_base_url(opts, endpoints) do
    case Keyword.pop(opts, :base_url) do
      {nil, opts} ->
        opts

      {base_url, opts} ->
        Enum.reduce(endpoints, opts, fn {key, path}, acc -> Keyword.put_new(acc, key, endpoint(base_url, path)) end)
    end
  end

  @doc false
  def user_agent(opts, default), do: {"user-agent", Keyword.get(opts, :user_agent, default)}

  # Per-call `:api_key`, `:transport`, `:transport_opts` and `:timeout` override
  # the client's own; a per-call `:endpoint` overrides `endpoint`.
  @doc false
  def http(provider, client, endpoint, opts, headers \\ []) do
    %HTTPClient{
      provider: provider,
      endpoint: endpoint,
      api_key: Keyword.get(opts, :api_key, client.api_key),
      auth_header: "authorization",
      auth_prefix: "Bearer",
      default_headers: headers ++ Request.normalize_headers(client.default_headers),
      transport: Keyword.get(opts, :transport, client.transport),
      transport_opts: Keyword.get(opts, :transport_opts, client.transport_opts),
      timeout: Keyword.get(opts, :timeout, client.timeout)
    }
  end
end
