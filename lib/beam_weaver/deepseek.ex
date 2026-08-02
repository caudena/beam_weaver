defmodule BeamWeaver.DeepSeek do
  @moduledoc """
  DeepSeek provider namespace.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.DeepSeek.ChatModel
  alias BeamWeaver.DeepSeek.ResponsesModel
  alias BeamWeaver.DeepSeek.Tools

  @default_base_url "https://api.deepseek.com"

  @doc "Builds the default DeepSeek Chat Completions model."
  @spec chat_model(keyword() | map()) :: ChatModel.t()
  def chat_model(opts \\ []) do
    opts
    |> normalize_opts()
    |> provider_opts()
    |> ChatModel.new()
  end

  @doc "Builds an explicit DeepSeek Chat Completions model."
  @spec chat_completions_model(keyword() | map()) :: ChatModel.t()
  def chat_completions_model(opts \\ []), do: chat_model(opts)

  @doc "Builds an explicit DeepSeek Responses API model."
  @spec responses_model(keyword() | map()) :: ResponsesModel.t()
  def responses_model(opts \\ []) do
    opts
    |> normalize_opts()
    |> provider_opts()
    |> ResponsesModel.new()
  end

  @doc "Returns DeepSeek tool declaration helpers."
  @spec tools() :: module()
  def tools, do: Tools

  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(opts), do: opts

  defp provider_opts(opts) do
    opts
    |> Keyword.delete(:api)
    |> Keyword.put_new(:api_key, Config.get([:deepseek, :api_key]))
    |> Keyword.put_new(:base_url, configured_base_url(opts))
  end

  defp configured_base_url(opts) do
    if Keyword.has_key?(opts, :base_url) do
      Keyword.fetch!(opts, :base_url) || @default_base_url
    else
      Config.get([:deepseek, :base_url], @default_base_url)
    end
  end
end
