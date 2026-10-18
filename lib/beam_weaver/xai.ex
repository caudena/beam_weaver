defmodule BeamWeaver.XAI do
  @moduledoc """
  xAI provider namespace.
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
