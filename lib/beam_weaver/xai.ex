defmodule BeamWeaver.XAI do
  @moduledoc ~S"""
  Grok Responses and Chat Completions with supported hosted-tool declarations.

  Constructors return configured values; invocation makes the provider request.
  Load credentials into `config :beam_weaver, :xai` in your application's
  runtime configuration. Explicit connection options override configured defaults.
  See the [XAI guide](providers/xai.md) for an executed request, endpoint
  choices, supported options and account/resource requirements.

  Native tool helpers construct declarations. Hosted tools execute at the provider;
  client actions require an application executor. Keep full returned messages
  for continuation and inspect outcomes rather than HTTP success alone.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.XAI.ChatCompletionsModel
  alias BeamWeaver.XAI.ChatModel
  alias BeamWeaver.XAI.Tools

  @default_base_url "https://api.x.ai/v1"

  @doc """
  Builds an xAI Responses API chat model.
  """
  @spec chat_model(keyword()) :: ChatModel.t()
  def chat_model(opts \\ []) do
    opts
    |> provider_opts("responses")
    |> ChatModel.new()
  end

  @doc """
  Builds an explicit xAI Responses API chat model.
  """
  @spec responses_model(keyword()) :: ChatModel.t()
  def responses_model(opts \\ []), do: chat_model(opts)

  @doc """
  Builds an xAI Chat Completions chat model.
  """
  @spec chat_completions_model(keyword()) :: ChatCompletionsModel.t()
  def chat_completions_model(opts \\ []) do
    opts
    |> provider_opts("chat/completions")
    |> ChatCompletionsModel.new()
  end

  @doc """
  Returns xAI tool declaration helpers.
  """
  @spec tools() :: module()
  def tools, do: Tools

  defp provider_opts(opts, endpoint_path) do
    opts
    |> Keyword.put_new_lazy(:api_key, fn -> Config.get([:xai, :api_key]) end)
    |> Compat.put_endpoint(:endpoint, :xai, @default_base_url, endpoint_path)
  end
end
