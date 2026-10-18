defmodule BeamWeaver.Moonshot do
  @moduledoc ~S"""
  Kimi Chat Completions with model-specific reasoning and tool contracts.

  Constructors return configured values; invocation makes the provider request.
  Load credentials into `config :beam_weaver, :moonshot` in your application's
  runtime configuration. Explicit connection options override configured defaults.
  See the [Moonshot guide](providers/moonshot.md) for an executed request, endpoint
  choices, supported options and account/resource requirements.

  Native tool helpers construct declarations. Hosted tools execute at the provider;
  client actions require an application executor. Keep full returned messages
  for continuation and inspect outcomes rather than HTTP success alone.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Moonshot.ChatModel
  alias BeamWeaver.Moonshot.Tools
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat

  @default_base_url "https://api.moonshot.ai/v1"

  @doc "Builds a Moonshot/Kimi Chat Completions chat model."
  @spec chat_model(keyword()) :: ChatModel.t()
  def chat_model(opts \\ []) do
    opts
    |> Keyword.put_new_lazy(:api_key, fn -> Config.get([:moonshot, :api_key]) end)
    |> Compat.put_endpoint(:endpoint, :moonshot, @default_base_url, "chat/completions")
    |> Compat.put_endpoint(:count_tokens_endpoint, :moonshot, @default_base_url, "tokenizers/estimate-token-count")
    |> ChatModel.new()
  end

  @doc "Returns Moonshot/Kimi tool declaration helpers."
  @spec tools() :: module()
  def tools, do: Tools
end
