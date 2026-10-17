defmodule BeamWeaver.Models do
  @moduledoc """
  Creates chat, embedding and decision models from `"provider:model"` strings,
  and wraps models with tools, structured output, a cache or a rate limiter.

  ```elixir
  {:ok, model} = BeamWeaver.Models.init_chat_model("fake:chat", responses: ["Hello, Ada."])
  {:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, [BeamWeaver.Core.Message.user("Hi, I'm Ada.")])
  reply.content
  #=> "Hello, Ada."
  ```

  The prefix picks the provider (`openai`, `anthropic`, `google`, `xai`,
  `deepseek`, `moonshot`, `zai`, `typesafe`, or `fake` for tests) and the rest
  is the provider's model id. Options such as `temperature:`, `max_tokens:` and
  `timeout:` follow the id; API keys come from your application config. See
  [Models](models.md) and [Providers](providers.md).
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.Registry, as: ProviderRegistry

  @doc "Wraps a chat model so that every call offers it `tools`."
  def bind_tools(model, tools, opts \\ []) do
    %BeamWeaver.Models.BoundTools{model: model, tools: tools, opts: opts}
  end

  @doc """
  Wraps a chat model so that every reply carries data matching `schema` in
  `metadata.structured_response`. See
  [Structured Output](structured_output.md#without-an-agent).
  """
  def with_structured_output(model, schema, opts \\ []) do
    %BeamWeaver.Models.StructuredOutput{model: model, schema: schema, opts: opts}
  end

  @doc """
  Wraps a chat model so that a repeated request is answered from `cache`
  (`BeamWeaver.Cache.ETS` or `BeamWeaver.Cache.Ecto`). Options such as `ttl:`
  apply to every entry. See [Caching](caching.md).
  """
  def cached(model, cache, opts \\ []) do
    %BeamWeaver.Models.Cached{model: model, cache: cache, opts: opts}
  end

  @doc """
  Wraps a model so that every call first takes tokens from a rate limiter.

  Options: `:limiter` (a bucket from `BeamWeaver.RateLimiter.start_bucket/1`,
  or its registered name), `:amount` (tokens per call, default 1), `:key` and
  `:timeout`. See [Rate Limiting](rate_limiting.md).
  """
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
  def with_tokenizer(%_{} = model, tokenizer), do: struct(model, tokenizer: tokenizer)

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
         {:ok, module} <- ProviderRegistry.chat_provider(provider, Keyword.put(opts, :model, model_id)),
         {:ok, profile} <- fetch_profile(provider, model_id, opts) do
      build_model(provider, module, model_id, opts, profile)
    end
  end

  @doc """
  Initializes a chat model and raises on failure.
  """
  def init_chat_model!(model_or_opts \\ [], opts \\ []),
    do: model_or_opts |> init_chat_model(opts) |> BeamWeaver.Policy.bang()

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
      build_model(provider, module, model_id, opts, profile)
    end
  end

  @doc """
  Initializes an embedding model and raises on failure.
  """
  def init_embeddings!(model_or_opts \\ [], opts \\ []),
    do: model_or_opts |> init_embeddings(opts) |> BeamWeaver.Policy.bang()

  @doc "Initializes a typed decision model using an explicit provider:model identifier."
  def init_decision_model(model_or_opts \\ [], opts \\ [])
  def init_decision_model(input, opts) when is_map(input), do: init_decision_model(Map.to_list(input), opts)

  def init_decision_model(input, opts) when is_list(input) do
    opts = Keyword.merge(input, opts)
    init_decision_model(Keyword.get(opts, :model, "typesafe:jev-latest"), opts)
  end

  def init_decision_model(model, opts) when is_atom(model), do: init_decision_model(Atom.to_string(model), opts)

  def init_decision_model(model, opts) when is_binary(model) do
    with [provider, id] when provider != "" and id != "" <- String.split(model, ":", parts: 2),
         provider = ProviderRegistry.provider_atom(provider),
         {:ok, module} <- ProviderRegistry.decision_provider(provider, opts),
         {:ok, profile} <- fetch_profile(provider, id, opts) do
      build_model(provider, module, id, opts, profile)
    else
      {:error, _} = error -> error
      _ -> {:error, Error.new(:invalid_model, "decision models require a provider: prefix", %{model: model})}
    end
  end

  @doc "Initializes a decision model and raises on invalid configuration."
  def init_decision_model!(model_or_opts \\ [], opts \\ []),
    do: model_or_opts |> init_decision_model(opts) |> BeamWeaver.Policy.bang()

  defp parse_model_id(model, kind) do
    case String.split(model, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        {:ok, ProviderRegistry.provider_atom(provider), model_id}

      ["jev-" <> _rest = model_id] ->
        {:error,
         Error.new(:unsupported_feature, "Jev requires Models.init_decision_model/2 with a typesafe: prefix", %{
           model: model_id
         })}

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

      ["glm-" <> _rest = model_id] when kind == :chat ->
        {:error,
         Error.new(:invalid_model, "GLM model identifiers require the zai: prefix", %{
           model: model_id,
           expected: "zai:#{model_id}"
         })}

      ["deepseek-" <> _rest = model_id] when kind == :chat ->
        {:error,
         Error.new(:invalid_model, "DeepSeek model identifiers require the deepseek: prefix", %{
           model: model_id,
           expected: "deepseek:#{model_id}"
         })}

      [model_id] when model_id != "" ->
        {:ok, ProviderRegistry.infer_provider(model_id, kind), model_id}

      _other ->
        {:error, Error.new(:invalid_model, "model identifier is invalid", %{model: model})}
    end
  end

  # The profile a model gets from its options: `:profile`, a
  # `:profile_registry`'s, or the provider's.
  @doc false
  @spec fetch_profile(atom(), String.t(), keyword()) :: {:ok, BeamWeaver.Models.Profile.t()} | {:error, Error.t()}
  def fetch_profile(provider, model_id, opts) do
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

  # A model takes its struct fields as options, plus the keys below. Anything
  # else is an error, so a misspelled or foreign option is never dropped. Call
  # options such as `tools:` belong to each call; `init_options/2` separates
  # them from an agent's model options.
  @api_models [
    BeamWeaver.OpenAI.ChatModel,
    BeamWeaver.OpenAI.ChatCompletionsModel,
    BeamWeaver.XAI.ChatModel,
    BeamWeaver.XAI.ChatCompletionsModel,
    BeamWeaver.DeepSeek.ChatModel,
    BeamWeaver.DeepSeek.ResponsesModel
  ]

  @base_url_models [
    BeamWeaver.OpenAI.ChatModel,
    BeamWeaver.OpenAI.ChatCompletionsModel,
    BeamWeaver.OpenAI.EmbeddingModel,
    BeamWeaver.Anthropic.ChatModel,
    BeamWeaver.XAI.ChatModel,
    BeamWeaver.XAI.ChatCompletionsModel,
    BeamWeaver.XAI.EmbeddingModel,
    BeamWeaver.Moonshot.ChatModel,
    BeamWeaver.ZAI.ChatModel
  ]

  @other_builtin_models [
    BeamWeaver.Anthropic.ChatModel,
    BeamWeaver.Google.ChatModel,
    BeamWeaver.Moonshot.ChatModel,
    BeamWeaver.ZAI.ChatModel,
    BeamWeaver.OpenAI.EmbeddingModel,
    BeamWeaver.XAI.EmbeddingModel,
    BeamWeaver.TypeSafe.DecisionModel,
    BeamWeaver.OpenAI.DecisionModel,
    BeamWeaver.Models.FakeChatModel,
    BeamWeaver.Models.FakeEmbeddingModel
  ]

  @builtin_models @api_models ++ @other_builtin_models

  # Options a model builds its client from. The fake chat model stands in for
  # any provider in tests, so it takes (and has no use for) the connection
  # options every provider takes.
  @client_options %{
    BeamWeaver.TypeSafe.DecisionModel => [:api_key, :base_url, :timeout, :transport, :transport_opts, :default_headers],
    BeamWeaver.OpenAI.DecisionModel => [
      :api_key,
      :base_url,
      :organization,
      :project,
      :timeout,
      :transport,
      :transport_opts,
      :default_headers
    ],
    BeamWeaver.Models.FakeChatModel => [
      :api_key,
      :base_url,
      :endpoint,
      :timeout,
      :transport,
      :transport_opts,
      :extra_body
    ]
  }

  # The output cap and stop sequences have one name per provider; the other
  # common names are accepted as aliases.
  @aliases %{
    BeamWeaver.Anthropic.ChatModel => [
      max_output_tokens: :max_tokens,
      max_completion_tokens: :max_tokens,
      stop: :stop_sequences
    ],
    BeamWeaver.Google.ChatModel => [
      max_tokens: :max_output_tokens,
      max_completion_tokens: :max_output_tokens,
      stop: :stop_sequences
    ]
  }

  # An agent's `model` options configure the model and are also sent with
  # every call. Returns the ones `init_chat_model/2` takes: the call options
  # among them, such as `tools:` or `tool_choice:`, are left to the calls, and
  # `tool_timeout:` to the agent's tool step. Unknown options stay, so
  # `init_chat_model/2` reports them.
  @doc false
  @spec init_options(String.t() | atom() | term(), keyword()) :: keyword()
  def init_options(model, opts) when is_atom(model) and not is_nil(model),
    do: init_options(Atom.to_string(model), opts)

  def init_options(model, opts) when is_binary(model) and is_list(opts) do
    opts = Keyword.delete(opts, :tool_timeout)

    with {:ok, provider, model_id} <- parse_model_id(model, :chat),
         {:ok, module} when module in @builtin_models <-
           ProviderRegistry.chat_provider(provider, Keyword.put(opts, :model, model_id)) do
      accepted = accepted_options(module)
      Enum.reject(opts, fn {key, _value} -> call_option?(key) and key not in accepted end)
    else
      _other -> opts
    end
  end

  def init_options(_model, opts), do: opts

  defp build_model(provider, module, model_id, opts, profile) do
    with {:ok, opts} <- validate_options(provider, module, model_id, opts, profile) do
      attrs =
        opts
        |> Keyword.drop([:model, :api, :profile_registry])
        |> rename_aliases(module)
        |> Keyword.put(:model, model_id)
        |> Keyword.put(:profile, profile)
        |> put_openai_defaults(module, model_id)

      {:ok, configured_model(attrs, module)}
    end
  end

  defp validate_options(provider, module, model_id, opts, profile) when module in @builtin_models do
    accepted = accepted_options(module)

    case opts |> Keyword.keys() |> Enum.uniq() |> Enum.reject(&(&1 in accepted)) do
      [] -> {:ok, opts}
      unknown -> {:error, unsupported_options_error(provider, module, model_id, unknown, profile)}
    end
  end

  # A model module of your own receives every option.
  defp validate_options(_provider, _module, _model_id, opts, _profile), do: {:ok, opts}

  defp accepted_options(module) do
    fields = struct_keys(module)

    shared =
      for {option, true} <- [
            stream: :streaming in fields,
            api: module in @api_models,
            base_url: module in @base_url_models
          ],
          do: option

    Enum.concat([
      fields,
      [:model, :profile_registry | shared],
      Keyword.keys(Map.get(@aliases, module, [])),
      Map.get(@client_options, module, [])
    ])
  end

  # Options the model takes on each call, such as `tools:`, get a hint.
  defp unsupported_options_error(provider, module, model_id, keys, profile) do
    call_options = Enum.filter(keys, &(call_option?(&1) and call_option_supported?(profile, &1)))

    hint =
      if call_options == [],
        do: "",
        else:
          "; pass #{Enum.map_join(call_options, ", ", &inspect/1)} when you call the model" <>
            if(:tools in call_options, do: ", or bind tools with BeamWeaver.Models.bind_tools/3", else: "")

    Error.new(
      :unsupported_model_param,
      "#{inspect(module)} does not take #{Enum.map_join(keys, ", ", &inspect/1)} when it is created" <> hint,
      %{provider: provider, model: model_id, params: keys}
    )
  end

  defp call_option_supported?(profile, key),
    do: BeamWeaver.Models.ParamPolicy.validate(profile, %{key => true}, :strict) == :ok

  defp call_option?(key), do: BeamWeaver.Models.ParamPolicy.standard_param?(key)

  defp rename_aliases(opts, module) do
    opts = if :streaming in struct_keys(module), do: rename(opts, :stream, :streaming), else: opts

    module
    |> then(&Map.get(@aliases, &1, []))
    |> Enum.reduce(opts, fn {from, to}, acc -> rename(acc, from, to) end)
  end

  # An alias never overrides the provider's own name for the option.
  defp rename(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put_new(opts, to, value)
    end
  end

  defp configured_model(opts, BeamWeaver.OpenAI.ChatModel), do: BeamWeaver.OpenAI.chat_model(opts)

  defp configured_model(opts, BeamWeaver.OpenAI.ChatCompletionsModel),
    do: BeamWeaver.OpenAI.chat_completions_model(opts)

  defp configured_model(opts, BeamWeaver.OpenAI.EmbeddingModel), do: BeamWeaver.OpenAI.embedding_model(opts)

  defp configured_model(opts, BeamWeaver.Anthropic.ChatModel), do: BeamWeaver.Anthropic.chat_model(opts)

  defp configured_model(opts, BeamWeaver.Google.ChatModel), do: BeamWeaver.Google.chat_model(opts)

  defp configured_model(opts, BeamWeaver.DeepSeek.ChatModel),
    do: BeamWeaver.DeepSeek.chat_model(opts)

  defp configured_model(opts, BeamWeaver.DeepSeek.ResponsesModel),
    do: BeamWeaver.DeepSeek.responses_model(opts)

  defp configured_model(opts, BeamWeaver.Moonshot.ChatModel), do: BeamWeaver.Moonshot.chat_model(opts)

  defp configured_model(opts, BeamWeaver.ZAI.ChatModel), do: BeamWeaver.ZAI.chat_model(opts)

  defp configured_model(opts, BeamWeaver.XAI.ChatModel), do: BeamWeaver.XAI.chat_model(opts)

  defp configured_model(opts, BeamWeaver.XAI.ChatCompletionsModel),
    do: BeamWeaver.XAI.chat_completions_model(opts)

  defp configured_model(opts, BeamWeaver.XAI.EmbeddingModel), do: BeamWeaver.XAI.embedding_model(opts)

  defp configured_model(opts, module) do
    if function_exported?(module, :new, 1) do
      module.new(opts)
    else
      struct(module, opts)
    end
  end

  defp put_openai_defaults(attrs, module, model_id)
       when module in [BeamWeaver.OpenAI.ChatModel, BeamWeaver.OpenAI.ChatCompletionsModel] do
    Keyword.put(
      attrs,
      :temperature,
      BeamWeaver.OpenAI.ModelPolicy.default_temperature(model_id, Keyword.get(attrs, :temperature))
    )
  end

  defp put_openai_defaults(attrs, _module, _model_id), do: attrs

  defp struct_keys(module) do
    module.__struct__()
    |> Map.from_struct()
    |> Map.keys()
  end
end
