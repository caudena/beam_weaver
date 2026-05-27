defmodule BeamWeaver.XAI do
  @moduledoc """
  xAI provider namespace.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.XAI.ChatCompletionsModel
  alias BeamWeaver.XAI.ChatModel
  alias BeamWeaver.XAI.Client
  alias BeamWeaver.XAI.EmbeddingModel
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
  Builds an xAI embeddings model.
  """
  @spec embedding_model(keyword()) :: EmbeddingModel.t()
  def embedding_model(opts \\ []) do
    opts
    |> provider_opts("embeddings")
    |> EmbeddingModel.new()
  end

  @doc """
  Returns xAI tool declaration helpers.
  """
  @spec tools() :: module()
  def tools, do: Tools

  defp provider_opts(opts, endpoint_path) do
    opts
    |> Keyword.put_new(:api_key, Config.get([:xai, :api_key]))
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
      Config.get([:xai, :base_url], @default_base_url)
    end
  end
end
