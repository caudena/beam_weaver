defprotocol BeamWeaver.Indexing.RecordManager.Backend do
  @moduledoc """
  Protocol dispatch for indexing record managers.
  """

  def get(manager, id, opts)
  def put(manager, record, opts)
  def list(manager, opts)
  def delete(manager, ids, opts)
end

defmodule BeamWeaver.Indexing.RecordManager do
  @moduledoc """
  Record manager contract for indexing cleanup and idempotence.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Indexing.Record
  alias BeamWeaver.Indexing.RecordManager.Backend, as: RecordManagerBackend

  @callback get(term(), String.t(), keyword()) :: {:ok, Record.t() | nil} | {:error, Error.t()}
  @callback put(term(), Record.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback list(term(), keyword()) :: {:ok, [Record.t()]} | {:error, Error.t()}
  @callback delete(term(), [String.t()], keyword()) :: :ok | {:error, Error.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Indexing.RecordManager

      defimpl BeamWeaver.Indexing.RecordManager.Backend, for: __MODULE__ do
        def get(manager, id, opts), do: @for.get(manager, id, opts)
        def put(manager, record, opts), do: @for.put(manager, record, opts)
        def list(manager, opts), do: @for.list(manager, opts)
        def delete(manager, ids, opts), do: @for.delete(manager, ids, opts)
      end
    end
  end

  def get(manager, id, opts \\ []), do: RecordManagerBackend.get(manager, id, opts)
  def put(manager, record, opts \\ []), do: RecordManagerBackend.put(manager, record, opts)
  def list(manager, opts \\ []), do: RecordManagerBackend.list(manager, opts)

  def delete(manager, ids, opts \\ []),
    do: RecordManagerBackend.delete(manager, List.wrap(ids), opts)

  @doc """
  Returns a monotonic-ish wall-clock timestamp for standard-test compatibility.
  """
  @spec get_time(term()) :: float()
  def get_time(_manager), do: System.system_time(:microsecond) / 1_000_000

  @doc """
  Upserts record keys with optional source/group IDs.

  This is the BeamWeaver-native equivalent of LangChain's `RecordManager.update`.
  Existing indexing code can still use `put/3` with explicit `%Record{}` structs
  when it needs hash metadata.
  """
  @spec update(term(), [String.t()], keyword()) :: :ok | {:error, Error.t()}
  def update(manager, keys, opts \\ []) when is_list(keys) do
    group_ids = Keyword.get(opts, :group_ids)
    namespace = Keyword.get(opts, :namespace, manager_namespace(manager))

    with :ok <- validate_group_ids(keys, group_ids),
         :ok <- validate_time_at_least(Keyword.get(opts, :time_at_least), get_time(manager)) do
      keys
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {key, index}, :ok ->
        source_id =
          case group_ids do
            nil -> nil
            values -> Enum.at(values, index)
          end

        record = %Record{
          id: to_string(key),
          source_id: if(is_nil(source_id), do: nil, else: to_string(source_id)),
          hash: Keyword.get(opts, :hash, to_string(key)),
          namespace: namespace,
          metadata: Keyword.get(opts, :metadata, %{}),
          updated_at: DateTime.utc_now()
        }

        case put(manager, record, namespace: namespace) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  @spec exists(term(), [String.t()], keyword()) :: [boolean()] | {:error, Error.t()}
  def exists(manager, keys, opts \\ []) when is_list(keys) do
    keys
    |> Enum.reduce_while([], fn key, acc ->
      case get(manager, to_string(key), opts) do
        {:ok, nil} -> {:cont, [false | acc]}
        {:ok, %Record{}} -> {:cont, [true | acc]}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, _error} = error -> error
      values -> Enum.reverse(values)
    end
  end

  @spec list_keys(term(), keyword()) :: [String.t()] | {:error, Error.t()}
  def list_keys(manager, opts \\ []) do
    before_time = Keyword.get(opts, :before)
    after_time = Keyword.get(opts, :after)
    group_ids = Keyword.get(opts, :group_ids)
    limit = Keyword.get(opts, :limit)
    list_opts = Keyword.take(opts, [:namespace]) ++ [source_ids: group_ids]

    with {:ok, records} <- list(manager, list_opts) do
      records
      |> Enum.filter(&(record_before?(&1, before_time) and record_after?(&1, after_time)))
      |> Enum.sort_by(&timestamp_value(&1.updated_at))
      |> maybe_take(limit)
      |> Enum.map(& &1.id)
    end
  end

  @spec delete_keys(term(), [String.t()], keyword()) :: :ok | {:error, Error.t()}
  def delete_keys(manager, keys, opts \\ []), do: delete(manager, keys, opts)

  @spec async_get(term(), String.t(), keyword()) :: Async.handle()
  def async_get(manager, id, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> get(manager, id, call_opts) end, async_opts)
  end

  @spec async_put(term(), Record.t(), keyword()) :: Async.handle()
  def async_put(manager, record, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> put(manager, record, call_opts) end, async_opts)
  end

  @spec async_list(term(), keyword()) :: Async.handle()
  def async_list(manager, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> list(manager, call_opts) end, async_opts)
  end

  @spec async_delete(term(), [String.t()], keyword()) :: Async.handle()
  def async_delete(manager, ids, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> delete(manager, ids, call_opts) end, async_opts)
  end

  @spec async_update(term(), [String.t()], keyword()) :: Async.handle()
  def async_update(manager, keys, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> update(manager, keys, call_opts) end, async_opts)
  end

  @spec async_exists(term(), [String.t()], keyword()) :: Async.handle()
  def async_exists(manager, keys, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> exists(manager, keys, call_opts) end, async_opts)
  end

  @spec async_list_keys(term(), keyword()) :: Async.handle()
  def async_list_keys(manager, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> list_keys(manager, call_opts) end, async_opts)
  end

  @spec async_delete_keys(term(), [String.t()], keyword()) :: Async.handle()
  def async_delete_keys(manager, keys, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> delete_keys(manager, keys, call_opts) end, async_opts)
  end

  defp validate_group_ids(_keys, nil), do: :ok

  defp validate_group_ids(keys, group_ids) when length(keys) == length(group_ids), do: :ok

  defp validate_group_ids(_keys, _group_ids),
    do: {:error, Error.new(:invalid_record_manager_update, "keys and group_ids length mismatch")}

  defp validate_time_at_least(nil, _now), do: :ok
  defp validate_time_at_least(time_at_least, now) when time_at_least <= now, do: :ok

  defp validate_time_at_least(_time_at_least, _now),
    do: {:error, Error.new(:invalid_record_manager_time, "time_at_least must not be in the future")}

  defp manager_namespace(%{namespace: namespace}), do: namespace
  defp manager_namespace(_manager), do: :default

  defp record_before?(_record, nil), do: true
  defp record_before?(record, before_time), do: timestamp_value(record.updated_at) < before_time

  defp record_after?(_record, nil), do: true
  defp record_after?(record, after_time), do: timestamp_value(record.updated_at) > after_time

  defp timestamp_value(%DateTime{} = datetime),
    do: DateTime.to_unix(datetime, :microsecond) / 1_000_000

  defp timestamp_value(nil), do: 0.0
  defp timestamp_value(value) when is_number(value), do: value

  defp maybe_take(values, nil), do: values
  defp maybe_take(values, limit) when is_integer(limit), do: Enum.take(values, limit)
end
