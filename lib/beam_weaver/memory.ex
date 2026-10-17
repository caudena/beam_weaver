defmodule BeamWeaver.Memory do
  @moduledoc """
  Long-term memory store helpers.

  Memory stores are independent from graph checkpoints. Checkpoints persist a
  thread's execution state; memory stores persist namespaced application data
  across threads and runs.
  """

  alias BeamWeaver.Adapter.Dispatch
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Memory.GetOp
  alias BeamWeaver.Memory.ListNamespacesOp
  alias BeamWeaver.Memory.MatchCondition
  alias BeamWeaver.Memory.PutOp
  alias BeamWeaver.Memory.Query
  alias BeamWeaver.Memory.SearchOp
  alias BeamWeaver.Result
  alias BeamWeaver.Telemetry.AdapterEvent
  alias BeamWeaver.Telemetry.AdapterHelpers

  @type store :: struct()
  @type namespace :: [String.t() | atom()] | String.t() | atom()
  @type key :: String.t() | atom()

  @spec put(store(), namespace(), key(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(store, namespace, key, value, opts \\ []), do: item_call(store, :put, namespace, key, [value, opts])

  @spec get(store(), namespace(), key()) :: {:ok, map()} | :error | {:error, term()}
  def get(store, namespace, key), do: item_call(store, :get, namespace, key, [])

  @spec delete(store(), namespace(), key()) :: :ok | {:error, term()}
  def delete(store, namespace, key), do: item_call(store, :delete, namespace, key, [])

  @doc """
  Retrieves the values of multiple keys from one namespace in the input order.

  Missing keys are returned as `nil`. If any read fails, the first error is
  returned as `{:error, error}`.
  """
  @spec get_many(store(), namespace(), [key()]) :: [term()] | {:error, term()}
  def get_many(store, namespace, keys) when is_list(keys) do
    namespace = normalize_namespace(namespace)

    with :ok <- Query.validate_namespace(namespace) do
      results = Enum.map(keys, &store_call(store, :get, [namespace, to_string(&1)]))

      case Enum.find(results, &match?({:error, _error}, &1)) do
        nil ->
          Enum.map(results, fn
            {:ok, item} -> item.value
            :error -> nil
          end)

        error ->
          error
      end
    end
  end

  @doc """
  Stores multiple key/value pairs in one namespace.
  """
  @spec put_many(store(), namespace(), [{key(), term()}], keyword()) :: :ok | {:error, term()}
  def put_many(store, namespace, key_value_pairs, opts \\ []) when is_list(key_value_pairs) do
    namespace = normalize_namespace(namespace)

    with :ok <- Query.validate_namespace(namespace) do
      key_value_pairs
      |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
        case store_call(store, :put, [namespace, to_string(key), value, opts]) do
          {:ok, _item} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  @doc """
  Deletes multiple keys from one namespace. Missing keys are ignored.
  """
  @spec delete_many(store(), namespace(), [key()]) :: :ok | {:error, term()}
  def delete_many(store, namespace, keys) when is_list(keys) do
    namespace = normalize_namespace(namespace)

    with :ok <- Query.validate_namespace(namespace) do
      keys
      |> Enum.reduce_while(:ok, fn key, :ok ->
        case store_call(store, :delete, [namespace, to_string(key)]) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  @doc """
  Returns keys in one namespace, optionally filtered by a string prefix.
  """
  @spec yield_keys(store(), namespace(), keyword()) :: Enumerable.t() | {:error, term()}
  def yield_keys(store, namespace, opts \\ []) do
    namespace = normalize_namespace(namespace)
    prefix = Keyword.get(opts, :prefix)

    with :ok <- Query.validate_namespace(namespace) do
      store
      |> search(namespace, limit: Keyword.get(opts, :limit, 100_000))
      |> case do
        {:error, _error} = error ->
          error

        items ->
          items
          |> Enum.map(& &1.key)
          |> Enum.filter(fn key ->
            is_nil(prefix) or String.starts_with?(to_string(key), to_string(prefix))
          end)
          |> Enum.sort()
      end
    end
  end

  @spec search(store(), namespace(), keyword()) :: [map()] | {:error, term()}
  def search(store, namespace, opts \\ []) do
    namespace = normalize_namespace(namespace)
    result = with :ok <- Query.validate_prefix(namespace), do: store_call(store, :search, [namespace, opts])

    emit(store, :search, %{count: AdapterHelpers.result_count(result)}, %{
      namespace: namespace,
      query: Keyword.get(opts, :query),
      filter: Keyword.get(opts, :filter),
      result: result
    })

    result
  end

  @spec list_namespaces(store(), keyword()) :: [[String.t()]] | {:error, term()}
  def list_namespaces(store, opts \\ []) do
    opts =
      opts
      |> Keyword.update(:prefix, [], &normalize_namespace/1)
      |> Keyword.update(:suffix, [], &normalize_namespace/1)

    result =
      with :ok <- Query.validate_prefix(opts[:prefix]),
           :ok <- Query.validate_prefix(opts[:suffix]),
           do: store_call(store, :list_namespaces, [opts])

    emit(store, :list_namespaces, %{count: AdapterHelpers.result_count(result)}, %{result: result})

    result
  end

  @doc """
  Extracts string values from nested data using BeamWeaver memory path syntax.

  Supports root (`"$"` or `""`), dotted keys, list indexes, negative indexes,
  wildcards, and brace unions such as `"items[*].{id,value}"`.
  """
  @spec get_text_at_path(term(), String.t() | list()) :: [String.t()]
  def get_text_at_path(value, path), do: Query.get_text_at_path(value, path)

  @doc """
  Tokenizes a memory path once for reuse with `get_text_at_path/2`.
  """
  @spec tokenize_path(String.t() | list()) :: {:ok, list()} | :error
  def tokenize_path(path), do: Query.tokenize_path(path)

  @doc """
  Runs `BeamWeaver.Memory.GetOp`, `BeamWeaver.Memory.PutOp`,
  `BeamWeaver.Memory.SearchOp` and `BeamWeaver.Memory.ListNamespacesOp`
  operations in order and returns one result for each: an item or `nil` for
  a get, `nil` for a put, a list for a search or a listing, and
  `{:error, error}` for an operation that failed.

  Namespaces and keys are normalized as in `put/5`. If any operation has an
  invalid namespace, none runs and the batch returns
  `{:error, {:invalid_namespace, message}}`.
  """
  @spec batch(store(), [struct()]) :: [term()] | {:error, term()}
  def batch(store, ops) when is_list(ops) do
    result = with {:ok, ops} <- Result.traverse(ops, &normalize_op/1), do: store_call(store, :batch, [ops])
    emit(store, :batch, %{count: length(ops)}, %{result: result})
    result
  end

  @spec sweep_expired(store(), keyword()) ::
          {:ok, non_neg_integer()} | :ok | {:error, Error.t()}
  def sweep_expired(store, opts \\ []) do
    result = BeamWeaver.Adapter.Sweepable.sweep_expired(store, opts)
    emit(store, :sweep, %{count: AdapterHelpers.sweep_count(result)}, %{result: result})
    result
  end

  @spec prune(store(), keyword()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def prune(store, opts \\ []) do
    opts =
      Keyword.update(opts, :namespace, nil, fn
        nil -> nil
        namespace -> normalize_namespace(namespace)
      end)

    result = BeamWeaver.Adapter.Retainable.prune(store, opts)

    emit(store, :prune, %{count: AdapterHelpers.sweep_count(result)}, %{
      namespace: Keyword.get(opts, :namespace),
      result: result
    })

    result
  end

  @spec normalize_namespace(namespace()) :: [String.t()]
  def normalize_namespace(namespace), do: Query.normalize_namespace(namespace)

  defp item_call(store, operation, namespace, key, args) do
    namespace = normalize_namespace(namespace)

    result =
      with :ok <- Query.validate_namespace(namespace),
           do: store_call(store, operation, [namespace, to_string(key) | args])

    emit(store, operation, %{count: 1}, namespace: namespace, key: key, result: result)
    result
  end

  defp normalize_op(%op{namespace: namespace, key: key} = struct) when op in [GetOp, PutOp] do
    namespace = normalize_namespace(namespace)

    with :ok <- Query.validate_batch_namespace(namespace),
         do: {:ok, %{struct | namespace: namespace, key: to_string(key)}}
  end

  defp normalize_op(%SearchOp{namespace: prefix} = op) do
    prefix = normalize_namespace(prefix)
    with :ok <- Query.validate_prefix(prefix), do: {:ok, %{op | namespace: prefix}}
  end

  defp normalize_op(%ListNamespacesOp{match_conditions: conditions} = op) do
    with {:ok, conditions} <- Result.traverse(conditions || [], &normalize_condition/1),
         do: {:ok, %{op | match_conditions: conditions}}
  end

  defp normalize_op(op), do: {:ok, op}

  defp normalize_condition(%MatchCondition{path: path} = condition) do
    path = normalize_namespace(path)
    with :ok <- Query.validate_prefix(path), do: {:ok, %{condition | path: path}}
  end

  defp normalize_condition(condition), do: {:ok, condition}

  defp store_call(store, callback, args) do
    Dispatch.call(store, callback, args,
      error_type: :invalid_memory_store,
      missing_message: "memory store does not implement BeamWeaver.Memory.Store",
      invalid_message: "memory store must be an explicit BeamWeaver.Memory.Store adapter"
    )
  end

  defp emit(store, operation, measurements, metadata) do
    result = AdapterHelpers.metadata_get(metadata, :result)

    BeamWeaver.Telemetry.emit(
      [:beam_weaver, :memory, operation],
      measurements,
      %AdapterEvent{
        adapter: AdapterHelpers.adapter_name(store),
        operation: operation,
        namespace: AdapterHelpers.metadata_get(metadata, :namespace),
        key: AdapterHelpers.metadata_get(metadata, :key),
        query: AdapterHelpers.metadata_get(metadata, :query),
        filter: AdapterHelpers.metadata_get(metadata, :filter),
        result: AdapterHelpers.result_type(result, miss_values: [:error]),
        error: AdapterHelpers.error_type(result)
      }
    )
  end
end
