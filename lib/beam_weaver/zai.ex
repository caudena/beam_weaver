defmodule BeamWeaver.ZAI do
  @moduledoc """
  Z.ai provider namespace.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.ZAI.ChatModel
  alias BeamWeaver.ZAI.Client
  alias BeamWeaver.ZAI.Tools

  @default_base_url "https://api.z.ai/api/paas/v4"

  @doc "Builds a Z.ai GLM Chat Completions chat model."
  @spec chat_model(keyword() | map()) :: ChatModel.t()
  def chat_model(opts \\ []) do
    opts
    |> normalize_opts()
    |> provider_opts("chat/completions")
    |> ChatModel.new()
  end

  @doc "Returns Z.ai tool declaration helpers."
  @spec tools() :: module()
  def tools, do: Tools

  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(opts), do: opts

  defp provider_opts(opts, endpoint_path) do
    opts
    |> Keyword.put_new(:api_key, Config.get([:zai, :api_key]))
    |> put_endpoint_default(endpoint_path)
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

  defp configured_base_url(opts) do
    if Keyword.has_key?(opts, :base_url) do
      Keyword.fetch!(opts, :base_url) || @default_base_url
    else
      Config.get([:zai, :base_url], @default_base_url)
    end
  end
end
