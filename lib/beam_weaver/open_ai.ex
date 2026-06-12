defmodule BeamWeaver.OpenAI do
  @moduledoc """
  OpenAI provider namespace for non-Azure first-skeleton support.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.OpenAI.ChatCompletionsModel
  alias BeamWeaver.OpenAI.ChatModel
  alias BeamWeaver.OpenAI.EmbeddingModel
  alias BeamWeaver.OpenAI.ModerationMiddleware
  alias BeamWeaver.OpenAI.Responses
  alias BeamWeaver.OpenAI.ResponsesModel
  alias BeamWeaver.OpenAI.ToolCalling

  @doc """
  Builds an OpenAI Responses API chat model.
  """
  @spec chat_model(keyword()) :: ChatModel.t()
  def chat_model(opts \\ []) do
    opts
    |> provider_opts("responses")
    |> ChatModel.new()
  end

  @doc """
  Builds an explicit OpenAI Responses API chat model.
  """
  @spec responses_model(keyword()) :: ResponsesModel.t()
  def responses_model(opts \\ []) do
    opts
    |> provider_opts("responses")
    |> ChatModel.new()
    |> Map.from_struct()
    |> then(&struct(ResponsesModel, &1))
  end

  @doc """
  Builds an OpenAI Chat Completions API chat model.
  """
  @spec chat_completions_model(keyword()) :: ChatCompletionsModel.t()
  def chat_completions_model(opts \\ []) do
    opts
    |> provider_opts("chat/completions")
    |> ChatCompletionsModel.new()
  end

  @doc """
  Builds an OpenAI embeddings model.
  """
  @spec embedding_model(keyword()) :: EmbeddingModel.t()
  def embedding_model(opts \\ []) do
    struct(EmbeddingModel, provider_opts(opts, "embeddings"))
  end

  @doc """
  Builds an OpenAI moderation agent middleware.
  """
  @spec moderation_middleware(keyword()) :: ModerationMiddleware.t()
  def moderation_middleware(opts \\ []) do
    opts
    |> provider_opts("moderations")
    |> ModerationMiddleware.new()
  end

  @doc """
  Returns the OpenAI tool declaration helpers.
  """
  @spec tools() :: module()
  def tools, do: ToolCalling

  @doc """
  Returns Responses API input-item helpers.
  """
  @spec responses() :: module()
  def responses, do: Responses

  defp provider_opts(opts, _endpoint_path) do
    opts
    |> Keyword.put_new(:api_key, Config.get([:openai, :api_key]))
    |> Keyword.put_new(:organization, Config.get([:openai, :organization]))
    |> Keyword.put_new(:project, Config.get([:openai, :project]))
  end
end
