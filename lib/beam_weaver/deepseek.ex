defmodule BeamWeaver.DeepSeek do
  @moduledoc ~S"""
  Chat Completions and stateless Responses, plus native client operations.

  Constructors return configured values; invocation makes the provider request.
  Load credentials into `config :beam_weaver, :deepseek` in your application's
  runtime configuration. Explicit connection options override configured defaults.
  See the [DeepSeek guide](providers/deepseek.md) for an executed request, endpoint
  choices, supported options and account/resource requirements.

  Native tool helpers construct declarations. Hosted tools execute at the provider;
  client actions require an application executor. Keep full returned messages
  for continuation and inspect outcomes rather than HTTP success alone.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.DeepSeek.ChatModel
  alias BeamWeaver.DeepSeek.ResponsesModel
  alias BeamWeaver.DeepSeek.Tools
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions

  @default_base_url "https://api.deepseek.com"

  @doc "Builds the default DeepSeek Chat Completions model."
  @spec chat_model(keyword() | map()) :: ChatModel.t()
  def chat_model(opts \\ []) do
    opts
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
    |> provider_opts()
    |> ResponsesModel.new()
  end

  @doc "Returns DeepSeek tool declaration helpers."
  @spec tools() :: module()
  def tools, do: Tools

  defp provider_opts(opts) do
    opts
    |> ChatOptions.keyword_options()
    |> Keyword.delete(:api)
    |> Keyword.put_new(:api_key, Config.get([:deepseek, :api_key]))
    |> Keyword.put_new_lazy(:base_url, fn -> Config.get([:deepseek, :base_url], @default_base_url) end)
  end
end
