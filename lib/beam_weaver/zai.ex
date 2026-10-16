defmodule BeamWeaver.ZAI do
  @moduledoc """
  Z.ai provider namespace.
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
    |> provider_opts("chat/completions")
    |> ChatModel.new()
  end

  @doc "Returns Z.ai tool declaration helpers."
  @spec tools() :: module()
  def tools, do: Tools

  defp provider_opts(opts, endpoint_path) do
    opts
    |> Keyword.put_new_lazy(:api_key, fn -> Config.get([:zai, :api_key]) end)
    |> Compat.put_endpoint(:endpoint, :zai, @default_base_url, endpoint_path)
  end
end
