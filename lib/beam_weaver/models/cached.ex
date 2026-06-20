defmodule BeamWeaver.Models.Cached do
  @moduledoc false

  @behaviour BeamWeaver.Core.ChatModel
  @behaviour BeamWeaver.Core.LLM

  alias BeamWeaver.Cache
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.LLM
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  defstruct [:model, :cache, opts: []]

  @impl true
  def invoke(%__MODULE__{} = wrapper, messages, opts) when is_list(messages) do
    with {:ok, cache} <- resolve_cache(wrapper, opts) do
      namespace = {:chat_model, model_name(wrapper.model)}
      key = cache_key(wrapper, messages, opts)

      case Cache.lookup(cache, namespace, key) do
        {:hit, message, _metadata} ->
          {:ok, zero_cached_cost(message)}

        :miss ->
          with {:ok, message} <- ChatModel.invoke(wrapper.model, messages, opts),
               :ok <- Cache.put(cache, namespace, key, message, wrapper.opts) do
            {:ok, message}
          end

        {:error, %Error{}} = error ->
          error
      end
    end
  end

  @impl true
  def stream(%__MODULE__{} = wrapper, messages, opts) when is_list(messages) do
    with {:ok, cache} <- resolve_cache(wrapper, opts) do
      namespace = {:chat_model, model_name(wrapper.model)}
      key = cache_key(wrapper, messages, opts)

      case Cache.lookup(cache, namespace, key) do
        {:hit, message, _metadata} ->
          {:ok, [zero_cached_cost(message)]}

        :miss ->
          with {:ok, message} <- ChatModel.invoke(wrapper.model, messages, opts),
               :ok <- Cache.put(cache, namespace, key, message, wrapper.opts) do
            {:ok, [message]}
          end

        {:error, %Error{}} = error ->
          error
      end
    end
  end

  def stream(%__MODULE__{} = wrapper, prompt, opts) when is_binary(prompt) do
    with {:ok, cache} <- resolve_cache(wrapper, opts) do
      namespace = {:llm, model_name(wrapper.model)}
      key = cache_key(wrapper, prompt, opts)

      case Cache.lookup(cache, namespace, key) do
        {:hit, completion, _metadata} when is_binary(completion) ->
          {:ok, [completion]}

        {:hit, completion, _metadata} ->
          {:error,
           Error.new(:invalid_cache_entry, "cached LLM completion must be a string", %{
             cached: inspect(completion)
           })}

        :miss ->
          with {:ok, chunks} <- LLM.stream(wrapper.model, prompt, opts),
               chunk_list <- Enum.to_list(chunks),
               completion <- Enum.join(chunk_list),
               :ok <- Cache.put(cache, namespace, key, completion, wrapper.opts) do
            {:ok, chunk_list}
          end

        {:error, %Error{}} = error ->
          error
      end
    end
  end

  @impl true
  def stream_events(%__MODULE__{} = wrapper, messages, opts) when is_list(messages) do
    with {:ok, cache} <- resolve_cache(wrapper, opts) do
      namespace = {:chat_model, model_name(wrapper.model)}
      key = cache_key(wrapper, messages, opts)

      case Cache.lookup(cache, namespace, key) do
        {:hit, message, metadata} ->
          {:ok, cached_event_stream(message, :hit, metadata)}

        :miss ->
          with {:ok, message} <- ChatModel.invoke(wrapper.model, messages, opts),
               :ok <- Cache.put(cache, namespace, key, message, wrapper.opts) do
            {:ok, cached_event_stream(message, :miss, %{})}
          end

        {:error, %Error{}} = error ->
          error
      end
    end
  end

  @impl true
  def complete(%__MODULE__{} = wrapper, prompt, opts) when is_binary(prompt) do
    with {:ok, cache} <- resolve_cache(wrapper, opts) do
      namespace = {:llm, model_name(wrapper.model)}
      key = cache_key(wrapper, prompt, opts)

      case Cache.lookup(cache, namespace, key) do
        {:hit, completion, _metadata} when is_binary(completion) ->
          {:ok, completion}

        {:hit, completion, _metadata} ->
          {:error,
           Error.new(:invalid_cache_entry, "cached LLM completion must be a string", %{
             cached: inspect(completion)
           })}

        :miss ->
          with {:ok, completion} <- LLM.complete(wrapper.model, prompt, opts),
               :ok <- Cache.put(cache, namespace, key, completion, wrapper.opts) do
            {:ok, completion}
          end

        {:error, %Error{}} = error ->
          error
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
        if Cache.adapter?(cache) do
          {:ok, cache}
        else
          {:error, Error.new(:invalid_cache, "model cache must be a BeamWeaver.Cache adapter")}
        end
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
  defp model_name(module) when is_atom(module), do: inspect(module)
  defp model_name(other), do: inspect(other)

  defp cached_event_stream(message, cache_status, cache_metadata) do
    message = if cache_status == :hit, do: zero_cached_cost(message), else: message

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
