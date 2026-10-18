defmodule BeamWeaver.ZAI do
  @moduledoc ~S"""
  GLM Chat Completions with reasoning, streamed arguments and supported media input.

  Constructors return configured values; invocation makes the provider request.
  Load credentials into `config :beam_weaver, :zai` in your application's
  runtime configuration. Explicit connection options override configured defaults.
  See the [ZAI guide](providers/zai.md) for an executed request, endpoint
  choices, supported options and account/resource requirements.

  Native tool helpers construct declarations. Hosted tools execute at the provider;
  client actions require an application executor. Keep full returned messages
  for continuation and inspect outcomes rather than HTTP success alone.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.ZAI.ChatModel
  alias BeamWeaver.ZAI.Tools

  @default_base_url "https://api.z.ai/api/paas/v4"

  @doc "Builds a Z.ai GLM Chat Completions chat model."
  @spec chat_model(keyword()) :: ChatModel.t()
  def chat_model(opts \\ []) do
    opts
    |> Keyword.put_new_lazy(:api_key, fn -> Config.get([:zai, :api_key]) end)
    |> Compat.put_endpoint(:endpoint, :zai, @default_base_url, "chat/completions")
    |> ChatModel.new()
  end

  @doc "Returns Z.ai tool declaration helpers."
  @spec tools() :: module()
  def tools, do: Tools
end
