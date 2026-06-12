defmodule BeamWeaver.OpenAI.EmbeddingModel do
  @moduledoc """
  OpenAI embeddings implementation for the first non-Azure provider surface.
  """

  @behaviour BeamWeaver.Core.EmbeddingModel

  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.Provider.EmbeddingRuntime
  alias BeamWeaver.Provider.Options

  @default_model "text-embedding-3-small"
  @default_endpoint "https://api.openai.com/v1/embeddings"
  @default_chunk_size 1_000
  @default_embedding_ctx_length 8_191

  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            organization: nil,
            project: nil,
            profile: nil,
            param_policy: nil,
            dimensions: nil,
            encoding_format: nil,
            user: nil,
            tokenizer: nil,
            check_embedding_ctx_length?: false,
            embedding_ctx_length: @default_embedding_ctx_length,
            allowed_special: [],
            disallowed_special: [],
            chunk_size: @default_chunk_size,
            skip_empty: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{
          model: String.t(),
          endpoint: String.t(),
          api_key: String.t() | nil,
          organization: String.t() | nil,
          project: String.t() | nil,
          dimensions: pos_integer() | nil,
          encoding_format: String.t() | atom() | nil,
          user: String.t() | nil,
          tokenizer: term() | nil,
          check_embedding_ctx_length?: boolean(),
          embedding_ctx_length: pos_integer(),
          chunk_size: pos_integer(),
          skip_empty: boolean(),
          transport: module(),
          transport_opts: keyword(),
          timeout: non_neg_integer()
        }

  @impl true
  def embed_documents(%__MODULE__{} = model, documents, opts \\ []) when is_list(documents) do
    embed_fun = fn input, call_opts -> embed_input(model, input, call_opts) end
    EmbeddingRuntime.embed_documents(model, documents, opts, embed_fun, runtime_error_opts())
  end

  @doc """
  Starts async document embedding.
  """
  @spec async_embed_documents(t(), [String.t()], keyword()) :: BeamWeaver.Core.Async.handle()
  def async_embed_documents(%__MODULE__{} = model, documents, opts \\ []) do
    EmbeddingRuntime.async_embed_documents(model, documents, opts, &embed_documents/3)
  end

  @impl true
  def embed_query(%__MODULE__{} = model, query, opts \\ []) when is_binary(query) do
    embed_fun = fn input, call_opts -> embed_input(model, input, call_opts) end
    EmbeddingRuntime.embed_query(model, query, opts, embed_fun, runtime_error_opts())
  end

  @doc """
  Starts async query embedding.
  """
  @spec async_embed_query(t(), String.t(), keyword()) :: BeamWeaver.Core.Async.handle()
  def async_embed_query(%__MODULE__{} = model, query, opts \\ []) do
    EmbeddingRuntime.async_embed_query(model, query, opts, &embed_query/3)
  end

  @doc """
  Starts an ordered async batch of query embeddings.
  """
  @spec async_batch_queries(t(), [String.t()], keyword()) :: [BeamWeaver.Core.Async.handle()]
  def async_batch_queries(%__MODULE__{} = model, queries, opts \\ []) when is_list(queries) do
    EmbeddingRuntime.async_batch_queries(model, queries, opts, &embed_query/3)
  end

  @doc """
  Builds the OpenAI embeddings request body.
  """
  @spec request_body(t(), String.t() | [String.t()], keyword()) :: map()
  def request_body(%__MODULE__{} = model, input, opts \\ []) do
    %{
      "model" => Keyword.get(opts, :model, model.model),
      "input" => input
    }
    |> Options.put_optional("dimensions", Keyword.get(opts, :dimensions, model.dimensions))
    |> Options.put_optional(
      "encoding_format",
      Options.normalize_value(Keyword.get(opts, :encoding_format, model.encoding_format))
    )
    |> Options.put_optional("user", Keyword.get(opts, :user, model.user))
    |> Options.merge_extra_body(Keyword.get(opts, :extra_body, %{}))
  end

  defp embed_input(%__MODULE__{} = model, input, opts) do
    body = request_body(model, input, opts)

    with :ok <- validate_request_params(model, opts),
         {:ok, response} <- Client.post_json(client(model), model.endpoint, body, opts) do
      embeddings_from_response(response)
    end
  end

  defp validate_request_params(%__MODULE__{} = model, opts) do
    params =
      model
      |> Map.from_struct()
      |> Map.take([:dimensions, :encoding_format, :user])
      |> Map.merge(Map.take(Map.new(opts), [:dimensions, :encoding_format, :extra_body, :model, :user]))

    ParamPolicy.validate(
      model.profile,
      params,
      Keyword.get(opts, :param_policy, model.param_policy),
      metadata: %{}
    )
  end

  defp embeddings_from_response(response),
    do: EmbeddingRuntime.embeddings_from_response(response, runtime_error_opts())

  defp client(%__MODULE__{} = model) do
    %Client{
      api_key: model.api_key,
      organization: model.organization,
      project: model.project,
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  defp runtime_error_opts, do: [error_module: Error, provider_name: "OpenAI"]
end
