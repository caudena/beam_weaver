defmodule BeamWeaver.Moonshot do
  @moduledoc """
  Moonshot/Kimi provider namespace.
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
