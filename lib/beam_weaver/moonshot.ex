defmodule BeamWeaver.Moonshot do
  @moduledoc """
  Moonshot/Kimi provider namespace.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Moonshot.ChatModel
  alias BeamWeaver.Moonshot.Client
  alias BeamWeaver.Moonshot.Tools

  @default_base_url "https://api.moonshot.ai/v1"

  @doc "Builds a Moonshot/Kimi Chat Completions chat model."
  @spec chat_model(keyword() | map()) :: ChatModel.t()
  def chat_model(opts \\ []) do
    opts
    |> normalize_opts()
    |> provider_opts("chat/completions")
    |> ChatModel.new()
  end

  @doc "Returns Moonshot/Kimi tool declaration helpers."
  @spec tools() :: module()
  def tools, do: Tools

  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(opts), do: opts

  defp provider_opts(opts, endpoint_path) do
    opts
    |> Keyword.put_new(:api_key, Config.get([:moonshot, :api_key]))
    |> put_endpoint_default(endpoint_path)
    |> put_count_tokens_endpoint()
  end

  defp put_endpoint_default(opts, endpoint_path) do
    cond do
      Keyword.has_key?(opts, :endpoint) ->
        opts

      base_url = configured_base_url(opts) ->
        Keyword.put(opts, :endpoint, Client.endpoint(base_url, endpoint_path))

      true ->
        opts
    end
  end

  defp put_count_tokens_endpoint(opts) do
    cond do
      Keyword.has_key?(opts, :count_tokens_endpoint) ->
        opts

      base_url = configured_base_url(opts) ->
        Keyword.put(
          opts,
          :count_tokens_endpoint,
          Client.endpoint(base_url, "tokenizers/estimate-token-count")
        )

      true ->
        opts
    end
  end

  defp configured_base_url(opts) do
    if Keyword.has_key?(opts, :base_url) do
      Keyword.fetch!(opts, :base_url) || @default_base_url
    else
      Config.get([:moonshot, :base_url], @default_base_url)
    end
  end
end
