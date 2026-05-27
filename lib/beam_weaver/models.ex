defmodule BeamWeaver.Models do
  @moduledoc """
  Model wrapper helpers.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.Registry, as: ProviderRegistry

  def bind_tools(model, tools, opts \\ []) do
    %BeamWeaver.Models.BoundTools{model: model, tools: tools, opts: opts}
  end

  def with_structured_output(model, schema, opts \\ []) do
    %BeamWeaver.Models.StructuredOutput{model: model, schema: schema, opts: opts}
  end

  def cached(model, cache, opts \\ []) do
    %BeamWeaver.Models.Cached{model: model, cache: cache, opts: opts}
  end

  def with_rate_limiter(model, opts \\ []) do
    %BeamWeaver.Models.RateLimited{
      model: model,
      policy: BeamWeaver.RateLimitPolicy.new!(opts)
    }
  end

  @doc """
  Returns an explicit tokenizer adapter suggested by a model or profile.
  """
  @spec tokenizer_for(term()) :: {:ok, term()} | nil
  def tokenizer_for(%BeamWeaver.Models.Profile{tokenizer: :static}),
    do: {:ok, %BeamWeaver.Tokenizer.StaticVocabulary{unknown_token: 0}}

  def tokenizer_for(%BeamWeaver.Models.Profile{tokenizer: tokenizer})
      when tokenizer in [:o200k_base, :cl100k_base, :p50k_base] do
    {:ok, %BeamWeaver.Tokenizer.OpenAI{encoding: tokenizer}}
  end

  def tokenizer_for(%BeamWeaver.Models.Profile{tokenizer: tokenizer}) when is_binary(tokenizer),
    do: {:ok, %BeamWeaver.Tokenizer.OpenAI{model: tokenizer}}

  def tokenizer_for(%BeamWeaver.Models.Profile{}), do: nil

  def tokenizer_for(%{tokenizer: tokenizer}) when not is_nil(tokenizer), do: {:ok, tokenizer}

  def tokenizer_for(%{profile: profile}) when not is_nil(profile), do: tokenizer_for(profile)

  def tokenizer_for(_value), do: nil

  @doc """
  Returns a copy of a model configured with an explicit tokenizer adapter.
  """
  @spec with_tokenizer(term(), term()) :: term()
  def with_tokenizer(%module{} = model, tokenizer) do
    if :tokenizer in struct_keys(module) do
      struct(model, tokenizer: tokenizer)
    else
      model
    end
  end

  @doc """
  Initializes a chat model from a provider-prefixed or inferred model identifier.
  """
  @spec init_chat_model(String.t() | atom() | map() | keyword(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def init_chat_model(model_or_opts \\ [], opts \\ [])

  def init_chat_model(opts, extra_opts) when is_list(opts) do
    model = Keyword.get(opts, :model) || Keyword.get(extra_opts, :model)
    init_chat_model(model || "openai:gpt-5.5", Keyword.merge(opts, extra_opts))
  end

  def init_chat_model(%{} = opts, extra_opts) do
    opts = Map.to_list(opts)
    init_chat_model(opts, extra_opts)
  end

  def init_chat_model(model, opts) when is_atom(model) do
    init_chat_model(Atom.to_string(model), opts)
  end

  def init_chat_model(model, opts) when is_binary(model) do
    with {:ok, provider, model_id} <- parse_model_id(model, :chat),
         {:ok, module} <- ProviderRegistry.chat_provider(provider, opts),
         {:ok, profile} <- fetch_profile(provider, model_id, opts) do
      {:ok, build_model(module, model_id, opts, profile)}
    end
  end

  @doc """
  Initializes a chat model and raises on failure.
  """
  def init_chat_model!(model_or_opts \\ [], opts \\ []) do
    case init_chat_model(model_or_opts, opts) do
      {:ok, model} -> model
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @doc """
  Initializes an embedding model from a provider-prefixed or inferred model identifier.
  """
  @spec init_embeddings(String.t() | atom() | map() | keyword(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def init_embeddings(model_or_opts \\ [], opts \\ [])

  def init_embeddings(opts, extra_opts) when is_list(opts) do
    model = Keyword.get(opts, :model) || Keyword.get(extra_opts, :model)
    init_embeddings(model || "openai:text-embedding-3-small", Keyword.merge(opts, extra_opts))
  end

  def init_embeddings(%{} = opts, extra_opts),
    do: opts |> Map.to_list() |> init_embeddings(extra_opts)

  def init_embeddings(model, opts) when is_atom(model),
    do: model |> Atom.to_string() |> init_embeddings(opts)

  def init_embeddings(model, opts) when is_binary(model) do
    with {:ok, provider, model_id} <- parse_model_id(model, :embedding),
         {:ok, module} <- ProviderRegistry.embedding_provider(provider, opts),
         {:ok, profile} <- fetch_profile(provider, model_id, opts) do
      {:ok, build_model(module, model_id, opts, profile)}
    end
  end

  @doc """
  Initializes an embedding model and raises on failure.
  """
  def init_embeddings!(model_or_opts \\ [], opts \\ []) do
    case init_embeddings(model_or_opts, opts) do
      {:ok, model} -> model
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp parse_model_id(model, kind) do
    case String.split(model, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        {:ok, ProviderRegistry.provider_atom(provider), model_id}

      ["gemini-" <> _rest = model_id] when kind == :chat ->
        {:error,
         Error.new(:invalid_model, "Gemini model identifiers require the google: prefix", %{
           model: model_id,
           expected: "google:#{model_id}"
         })}

      ["kimi-" <> _rest = model_id] when kind == :chat ->
        {:error,
         Error.new(:invalid_model, "Kimi model identifiers require the moonshot: prefix", %{
           model: model_id,
           expected: "moonshot:#{model_id}"
         })}

      [model_id] when model_id != "" ->
        {:ok, ProviderRegistry.infer_provider(model_id, kind), model_id}

      _other ->
        {:error, Error.new(:invalid_model, "model identifier is invalid", %{model: model})}
    end
  end

  defp fetch_profile(provider, model_id, opts) do
    cond do
      profile = Keyword.get(opts, :profile) ->
        {:ok, BeamWeaver.Models.Profile.new(profile)}

      registry = Keyword.get(opts, :profile_registry) ->
        fetch_profile_from_registry(registry, provider, model_id)

      true ->
        ProviderRegistry.profile(provider, model_id)
    end
  end

  defp fetch_profile_from_registry(module, provider, model_id) when is_atom(module) do
    if function_exported?(module, :fetch, 2) do
      module.fetch(provider, model_id)
    else
      {:error,
       Error.new(:invalid_profile_registry, "profile registry must implement fetch/2", %{
         registry: inspect(module)
       })}
    end
  end

  defp fetch_profile_from_registry(%{__struct__: module} = registry, provider, model_id) do
    if function_exported?(module, :fetch, 3) do
      module.fetch(registry, provider, model_id)
    else
      {:error,
       Error.new(:invalid_profile_registry, "profile registry struct must implement fetch/3", %{
         registry: inspect(module)
       })}
    end
  end

  defp fetch_profile_from_registry(_registry, _provider, _model_id) do
    {:error, Error.new(:invalid_profile_registry, "profile registry is invalid")}
  end

  defp build_model(BeamWeaver.Models.FakeChatModel, _model_id, opts, profile) do
    opts
    |> Map.new()
    |> Map.take([
      :response,
      :responses,
      :parent,
      :stream_chunks,
      :stream_events,
      :usage_metadata,
      :tokenizer,
      :param_policy,
      :tool_calls,
      :structured_response,
      :error
    ])
    |> Map.put(:profile, profile)
    |> then(&struct(BeamWeaver.Models.FakeChatModel, &1))
  end

  defp build_model(BeamWeaver.Models.FakeEmbeddingModel, _model_id, opts, profile) do
    opts
    |> Map.new()
    |> Map.take([:dimensions, :tokenizer, :param_policy, :error, :parent])
    |> Map.put(:profile, profile)
    |> then(&struct(BeamWeaver.Models.FakeEmbeddingModel, &1))
  end

  defp build_model(module, model_id, opts, profile) do
    attrs =
      opts
      |> Map.new()
      |> Map.take(struct_keys(module))
      |> Map.put(:model, model_id)
      |> Map.put(:profile, profile)
      |> put_openai_defaults(module, model_id)

    struct(module, attrs)
  end

  defp put_openai_defaults(attrs, module, model_id)
       when module in [BeamWeaver.OpenAI.ChatModel, BeamWeaver.OpenAI.ChatCompletionsModel] do
    Map.put(
      attrs,
      :temperature,
      BeamWeaver.OpenAI.ModelPolicy.default_temperature(model_id, Map.get(attrs, :temperature))
    )
  end

  defp put_openai_defaults(attrs, _module, _model_id), do: attrs

  defp struct_keys(module) do
    module.__struct__()
    |> Map.from_struct()
    |> Map.keys()
  end
end
