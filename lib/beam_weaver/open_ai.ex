defmodule BeamWeaver.OpenAI do
  @moduledoc ~S"""
  Responses and Chat Completions, with separate embedding, decision and image operations.

  Constructors return configured values; invocation makes the provider request.
  Load credentials into `config :beam_weaver, :openai` in your application's
  runtime configuration. Explicit connection options override configured defaults.
  See the [OpenAI guide](providers/openai.md) for an executed request, endpoint
  choices, supported options and account/resource requirements.

  Native tool helpers construct declarations. Hosted tools execute at the provider;
  client actions require an application executor. Keep full returned messages
  for continuation and inspect outcomes rather than HTTP success alone.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.OpenAI.ChatCompletionsModel
  alias BeamWeaver.OpenAI.ChatModel
  alias BeamWeaver.OpenAI.DecisionModel
  alias BeamWeaver.OpenAI.EmbeddingModel
  alias BeamWeaver.OpenAI.Images
  alias BeamWeaver.OpenAI.Responses
  alias BeamWeaver.OpenAI.ResponsesModel
  alias BeamWeaver.OpenAI.ToolCalling
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat

  @default_base_url "https://api.openai.com/v1"

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
    opts
    |> provider_opts("embeddings")
    |> EmbeddingModel.new()
  end

  @doc """
  Builds an OpenAI Decisions API model, `gpt-6-luna` unless `:model` names
  another. See `BeamWeaver.OpenAI.DecisionModel`.
  """
  @spec decision_model(keyword()) :: DecisionModel.t()
  def decision_model(opts \\ []), do: DecisionModel.new(opts)

  @doc "Generates images through the Images API and emits a priced generation observation."
  @spec generate_image(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_image(prompt, opts \\ []), do: Images.generate(prompt, provider_opts(opts, "images/generations"))

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

  # Key, organization and project come from `config :beam_weaver, :openai`
  # unless given; so does `base_url`, the API root the endpoint is built on.
  defp provider_opts(opts, endpoint_path) do
    opts
    |> Keyword.put_new(:api_key, Config.get([:openai, :api_key]))
    |> Keyword.put_new(:organization, Config.get([:openai, :organization]))
    |> Keyword.put_new(:project, Config.get([:openai, :project]))
    |> Compat.put_endpoint(:endpoint, :openai, @default_base_url, endpoint_path)
  end
end
