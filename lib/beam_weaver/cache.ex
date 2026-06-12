defmodule BeamWeaver.Cache do
  @moduledoc """
  Explicit cache contract for graph nodes and model wrappers.

  Cache adapters are ordinary structs implementing this behaviour. BeamWeaver
  does not keep a mutable global cache; callers pass a cache adapter at graph,
  agent, or model-wrapper boundaries.
  """

  alias BeamWeaver.Adapter.Dispatch
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Telemetry.AdapterEvent
  alias BeamWeaver.Telemetry.AdapterHelpers

  @type namespace :: term()
  @type key :: term()
  @type metadata :: map()
  @type lookup_result :: {:hit, term(), metadata()} | :miss | {:error, Error.t()}

  @callback lookup(term(), namespace(), key(), keyword()) :: lookup_result()
  @callback put(term(), namespace(), key(), term(), keyword()) :: :ok | {:error, Error.t()}
  @callback delete(term(), namespace(), key(), keyword()) :: :ok | {:error, Error.t()}
  @callback clear(term(), namespace() | nil, keyword()) :: :ok | {:error, Error.t()}

  @spec lookup(term(), namespace(), key(), keyword()) :: lookup_result()
  def lookup(cache, namespace, key, opts \\ []) do
    emit(cache, :lookup, %{count: 1}, %{namespace: namespace, key: key})

    case adapter(cache, :lookup) do
      {:ok, module} ->
        case module.lookup(cache, namespace, key, opts) do
          {:hit, _value, _metadata} = hit ->
            emit(cache, :hit, %{count: 1}, %{namespace: namespace, key: key, result: :hit})
            hit

          :miss ->
            emit(cache, :miss, %{count: 1}, %{namespace: namespace, key: key, result: :miss})
            :miss

          {:error, %Error{type: type}} = error ->
            emit(cache, :error, %{count: 1}, %{namespace: namespace, key: key, error: type})
            error
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @spec put(term(), namespace(), key(), term(), keyword()) :: :ok | {:error, Error.t()}
  def put(cache, namespace, key, value, opts \\ []) do
    with {:ok, module} <- adapter(cache, :put),
         :ok <- module.put(cache, namespace, key, value, opts) do
      emit(cache, :put, %{count: 1}, %{namespace: namespace, key: key, result: :ok})
      :ok
    end
  end

  @doc """
  Alias for `put/5` matching cache update terminology.
  """
  @spec update(term(), namespace(), key(), term(), keyword()) :: :ok | {:error, Error.t()}
  def update(cache, namespace, key, value, opts \\ []),
    do: put(cache, namespace, key, value, opts)

  @spec delete(term(), namespace(), key(), keyword()) :: :ok | {:error, Error.t()}
  def delete(cache, namespace, key, opts \\ []) do
    with {:ok, module} <- adapter(cache, :delete),
         :ok <- module.delete(cache, namespace, key, opts) do
      emit(cache, :delete, %{count: 1}, %{namespace: namespace, key: key, result: :ok})
      :ok
    end
  end

  @spec clear(term(), namespace() | nil, keyword()) :: :ok | {:error, Error.t()}
  def clear(cache, namespace \\ nil, opts \\ []) do
    with {:ok, module} <- adapter(cache, :clear),
         :ok <- module.clear(cache, namespace, opts) do
      emit(cache, :clear, %{count: 1}, %{namespace: namespace, result: :ok})
      :ok
    end
  end

  @doc """
  Looks up multiple `{namespace, key}` entries and returns a map of cache hits.

  Missing or expired entries are omitted. This is the native batch equivalent of
  LangGraph's `BaseCache.get/1` contract.
  """
  @spec get_many(term(), [{namespace(), key()}], keyword()) ::
          %{optional({namespace(), key()}) => term()} | {:error, Error.t()}
  def get_many(cache, full_keys, opts \\ []) when is_list(full_keys) do
    full_keys
    |> Enum.reduce_while(%{}, fn {namespace, key} = full_key, acc ->
      case lookup(cache, namespace, key, opts) do
        {:hit, value, _metadata} -> {:cont, Map.put(acc, full_key, value)}
        :miss -> {:cont, acc}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  Stores multiple `{namespace, key}` entries.

  Pair values may be raw values or `{value, ttl_seconds}` tuples. TTLs use
  seconds here to mirror LangGraph cache policy data; the underlying adapter
  still receives BeamWeaver's millisecond `:ttl` option.
  """
  @spec set_many(term(), map() | list(), keyword()) :: :ok | {:error, Error.t()}
  def set_many(cache, pairs, opts \\ []) when is_map(pairs) or is_list(pairs) do
    pairs
    |> Enum.reduce_while(:ok, fn {{namespace, key}, value_with_ttl}, :ok ->
      {value, ttl_seconds} = split_value_ttl(value_with_ttl)
      put_opts = maybe_put_ttl(opts, ttl_seconds)

      case put(cache, namespace, key, value, put_opts) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  Clears multiple namespaces, or the whole cache when `namespaces` is `nil`.
  """
  @spec clear_many(term(), [namespace()] | nil, keyword()) :: :ok | {:error, Error.t()}
  def clear_many(cache, namespaces \\ nil, opts \\ [])

  def clear_many(cache, nil, opts), do: clear(cache, nil, opts)

  def clear_many(cache, namespaces, opts) when is_list(namespaces) do
    namespaces
    |> Enum.reduce_while(:ok, fn namespace, :ok ->
      case clear(cache, namespace, opts) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Starts a Task-backed cache lookup."
  @spec async_lookup(term(), namespace(), key(), keyword()) :: Async.handle()
  def async_lookup(cache, namespace, key, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> lookup(cache, namespace, key, call_opts) end, async_opts)
  end

  @doc "Starts a Task-backed cache update."
  @spec async_put(term(), namespace(), key(), term(), keyword()) :: Async.handle()
  def async_put(cache, namespace, key, value, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> put(cache, namespace, key, value, call_opts) end, async_opts)
  end

  @doc "Starts a Task-backed cache update."
  @spec async_update(term(), namespace(), key(), term(), keyword()) :: Async.handle()
  def async_update(cache, namespace, key, value, opts \\ []) do
    async_put(cache, namespace, key, value, opts)
  end

  @doc "Starts a Task-backed cache delete."
  @spec async_delete(term(), namespace(), key(), keyword()) :: Async.handle()
  def async_delete(cache, namespace, key, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> delete(cache, namespace, key, call_opts) end, async_opts)
  end

  @doc "Starts a Task-backed cache clear."
  @spec async_clear(term(), namespace() | nil, keyword()) :: Async.handle()
  def async_clear(cache, namespace \\ nil, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> clear(cache, namespace, call_opts) end, async_opts)
  end

  @doc "Starts a Task-backed batch cache lookup."
  @spec async_get_many(term(), [{namespace(), key()}], keyword()) :: Async.handle()
  def async_get_many(cache, full_keys, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> get_many(cache, full_keys, call_opts) end, async_opts)
  end

  @doc "Starts a Task-backed batch cache update."
  @spec async_set_many(term(), map() | list(), keyword()) :: Async.handle()
  def async_set_many(cache, pairs, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> set_many(cache, pairs, call_opts) end, async_opts)
  end

  @doc "Starts a Task-backed batch namespace clear."
  @spec async_clear_many(term(), [namespace()] | nil, keyword()) :: Async.handle()
  def async_clear_many(cache, namespaces \\ nil, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> clear_many(cache, namespaces, call_opts) end, async_opts)
  end

  @spec sweep_expired(term(), keyword()) :: {:ok, non_neg_integer()} | :ok | {:error, Error.t()}
  def sweep_expired(cache, opts \\ []) do
    result = BeamWeaver.Adapter.Sweepable.sweep_expired(cache, opts)

    emit(cache, :sweep, %{count: AdapterHelpers.sweep_count(result)}, %{
      namespace: Keyword.get(opts, :namespace),
      result: AdapterHelpers.result_type(result),
      error: AdapterHelpers.error_type(result)
    })

    result
  end

  @spec prune(term(), keyword()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def prune(cache, opts \\ []) do
    result = BeamWeaver.Adapter.Retainable.prune(cache, opts)

    emit(cache, :prune, %{count: AdapterHelpers.sweep_count(result)}, %{
      namespace: Keyword.get(opts, :namespace),
      result: AdapterHelpers.result_type(result),
      error: AdapterHelpers.error_type(result)
    })

    result
  end

  @spec adapter?(term()) :: boolean()
  def adapter?(cache), do: match?({:ok, _module}, adapter(cache, :lookup))

  @spec explicit_required_error(map()) :: Error.t()
  def explicit_required_error(details \\ %{}) do
    Error.new(
      :explicit_cache_required,
      "cache: true requires an explicit BeamWeaver.Cache adapter",
      details
    )
  end

  @doc false
  @spec stable_key(term()) :: binary()
  def stable_key(payload) do
    payload
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp adapter(nil, _callback), do: {:error, explicit_required_error()}
  defp adapter(false, _callback), do: {:error, explicit_required_error()}
  defp adapter(true, _callback), do: {:error, explicit_required_error()}

  defp adapter(%{__struct__: _module} = cache, callback) do
    Dispatch.module(cache, callback, callback_arity(callback),
      error_type: :invalid_cache,
      missing_message: "cache adapter does not implement BeamWeaver.Cache",
      invalid_message: "cache must be an explicit BeamWeaver.Cache adapter"
    )
  end

  defp adapter(other, _callback) do
    {:error,
     Error.new(:invalid_cache, "cache must be an explicit BeamWeaver.Cache adapter", %{
       cache: inspect(other)
     })}
  end

  defp callback_arity(:lookup), do: 4
  defp callback_arity(:put), do: 5
  defp callback_arity(:delete), do: 4
  defp callback_arity(:clear), do: 3

  defp split_value_ttl({value, ttl}) when is_integer(ttl) or is_nil(ttl), do: {value, ttl}
  defp split_value_ttl(value), do: {value, nil}

  defp maybe_put_ttl(opts, nil), do: opts

  defp maybe_put_ttl(opts, ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds > 0,
    do: Keyword.put(opts, :ttl, ttl_seconds * 1_000)

  defp maybe_put_ttl(opts, _ttl_seconds), do: opts

  defp canonical(%{__struct__: module} = struct) do
    {:struct, module, canonical(Map.from_struct(struct))}
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {canonical(key), canonical(value)} end)
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)

  defp canonical(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&canonical/1)
    |> List.to_tuple()
  end

  defp canonical(fun) when is_function(fun), do: {:function, :erlang.fun_info(fun, :arity)}
  defp canonical(pid) when is_pid(pid), do: {:pid, inspect(pid)}
  defp canonical(ref) when is_reference(ref), do: {:reference, inspect(ref)}
  defp canonical(port) when is_port(port), do: {:port, inspect(port)}
  defp canonical(value), do: value

  defp emit(cache, event, measurements, metadata) do
    BeamWeaver.Telemetry.emit(
      [:beam_weaver, :cache, event],
      measurements,
      %AdapterEvent{
        adapter: AdapterHelpers.adapter_name(cache),
        operation: event,
        namespace: AdapterHelpers.metadata_get(metadata, :namespace),
        key: AdapterHelpers.metadata_get(metadata, :key),
        result: AdapterHelpers.metadata_get(metadata, :result),
        error: AdapterHelpers.metadata_get(metadata, :error),
        metadata: Map.drop(metadata, [:namespace, :key, :result, :error])
      }
    )
  end
end
