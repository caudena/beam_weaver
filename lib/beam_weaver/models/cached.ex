defmodule BeamWeaver.Models.Cached do
  @moduledoc false

  @behaviour BeamWeaver.Core.ChatModel
  @behaviour BeamWeaver.Core.DecisionModel

  alias BeamWeaver.Cache
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  defstruct [:model, :cache, opts: []]

  @impl true
  def decision_model?(wrapper), do: BeamWeaver.Core.DecisionModel.model?(wrapper.model)

  @impl true
  def evaluate(%__MODULE__{} = wrapper, input, opts) do
    key_opts =
      Keyword.drop(opts, [
        :run_id,
        :run_name,
        :tags,
        :metadata,
        :trace,
        :trace?,
        :exporter,
        :exporter_opts,
        :max_concurrency
      ])

    with :ok <- require_decision_model(wrapper) do
      case lookup(wrapper, :decision_model, input, key_opts) do
        {:hit, %response_module{} = response, _metadata}
        when response_module in [BeamWeaver.TypeSafe.Response, BeamWeaver.OpenAI.Decisions.Response] ->
          {:ok, response_module.cached(response)}

        {:hit, _value, _metadata} ->
          {:error, Error.new(:invalid_cache_entry, "cached value is not a decision response")}

        {:miss, store} ->
          with {:ok, response} <- BeamWeaver.Core.DecisionModel.invoke(wrapper.model, input, opts),
               :ok <- store.(response),
               do: {:ok, response}

        {:error, _} = error ->
          error
      end
    end
  end

  defp require_decision_model(wrapper) do
    if decision_model?(wrapper),
      do: :ok,
      else: {:error, Error.new(:unsupported_feature, "wrapped model does not support decisions")}
  end

  @impl true
  def invoke(%__MODULE__{} = wrapper, input, opts) when is_map(input), do: evaluate(wrapper, input, opts)

  def invoke(%__MODULE__{} = wrapper, messages, opts) when is_list(messages) do
    case lookup(wrapper, :chat_model, messages, opts) do
      {:hit, message, _metadata} ->
        {:ok, zero_cached_cost(message)}

      {:miss, store} ->
        with {:ok, message} <- ChatModel.invoke(wrapper.model, messages, opts),
             :ok <- store.(message),
             do: {:ok, message}

      {:error, %Error{}} = error ->
        error
    end
  end

  @impl true
  def stream(%__MODULE__{} = wrapper, input, opts) when is_map(input) or is_list(input) do
    with {:ok, value} <- invoke(wrapper, input, opts), do: {:ok, [value]}
  end

  @impl true
  def stream_events(%__MODULE__{} = wrapper, messages, opts) when is_list(messages) do
    case lookup(wrapper, :chat_model, messages, opts) do
      {:hit, message, metadata} ->
        {:ok, cached_event_stream(zero_cached_cost(message), :hit, metadata)}

      {:miss, store} ->
        with {:ok, message} <- ChatModel.invoke(wrapper.model, messages, opts),
             :ok <- store.(message),
             do: {:ok, cached_event_stream(message, :miss, %{})}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp lookup(wrapper, kind, input, opts) do
    with {:ok, cache} <- resolve_cache(wrapper, opts) do
      namespace = {kind, model_name(wrapper.model)}
      key = cache_key(wrapper, input, opts)

      case Cache.lookup(cache, namespace, key) do
        :miss -> {:miss, &Cache.put(cache, namespace, key, &1, wrapper.opts)}
        hit_or_error -> hit_or_error
      end
    end
  end

  defp cache_key(%__MODULE__{} = wrapper, messages, opts) do
    Cache.stable_key(
      {cacheable_model(wrapper.model), cacheable_input(messages), Keyword.drop(opts, runtime_cache_opts())}
    )
  end

  defp runtime_cache_opts do
    [:callbacks, :cache, :config, :rate_limiter, :stream_mode, :task_supervisor]
  end

  defp cacheable_input(messages) when is_list(messages) do
    Enum.map(messages, &cacheable_message/1)
  end

  defp cacheable_input(input), do: input

  defp cacheable_message(%Message{} = message), do: %{message | id: nil}
  defp cacheable_message(message), do: message

  defp cacheable_model(%{__struct__: module} = model) do
    fields =
      model
      |> Map.from_struct()
      |> Map.drop(runtime_model_fields())

    {:model, module, fields}
  end

  defp cacheable_model(model) when is_atom(model), do: {:model, model}
  defp cacheable_model(model), do: model

  defp runtime_model_fields do
    [
      :cache,
      :error,
      :limiter,
      :parent,
      :reply,
      :response,
      :responses,
      :stream_chunks,
      :stream_events,
      :structured_response,
      :usage_metadata
    ]
  end

  defp resolve_cache(%__MODULE__{cache: true}, opts) do
    case Keyword.get(opts, :cache) do
      cache when cache in [nil, false, true, %{}] ->
        {:error, Cache.explicit_required_error(%{model: "chat_model"})}

      cache ->
        resolve_cache(%__MODULE__{cache: cache}, opts)
    end
  end

  defp resolve_cache(%__MODULE__{cache: cache}, _opts) do
    if Cache.adapter?(cache) do
      {:ok, cache}
    else
      {:error, Error.new(:invalid_cache, "model cache must be a BeamWeaver.Cache adapter")}
    end
  end

  defp model_name(%{__struct__: module}), do: inspect(module)
  defp model_name(other), do: inspect(other)

  defp cached_event_stream(message, cache_status, cache_metadata) do
    [
      Stream.envelope(%Events.Debug{payload: %{type: :cache_replay, cache: cache_status}},
        metadata: %{cache: cache_status, cache_metadata: cache_metadata}
      ),
      Stream.envelope(%Events.Message{message: message}, metadata: %{cache: cache_status}),
      Stream.envelope(%Events.Done{result: message}, metadata: %{cache: cache_status})
    ]
  end

  defp zero_cached_cost(%Message{usage_metadata: metadata} = message) when is_map(metadata) do
    %{message | usage_metadata: metadata |> Map.put(:total_cost, 0) |> Map.put("total_cost", 0)}
  end

  defp zero_cached_cost(message), do: message
end
