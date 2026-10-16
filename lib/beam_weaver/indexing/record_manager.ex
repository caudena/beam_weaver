defmodule BeamWeaver.Indexing.RecordManager do
  @moduledoc """
  Record manager contract for indexing cleanup and idempotence.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Indexing.Record

  @callback get(term(), String.t(), keyword()) :: {:ok, Record.t() | nil} | {:error, Error.t()}
  @callback put(term(), Record.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback list(term(), keyword()) :: {:ok, [Record.t()]} | {:error, Error.t()}
  @callback delete(term(), [String.t()], keyword()) :: :ok | {:error, Error.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Indexing.RecordManager
    end
  end

  # Each function calls the record manager struct's module.
  def get(%module{} = manager, id, opts \\ []), do: module.get(manager, id, opts)
  def put(%module{} = manager, record, opts \\ []), do: module.put(manager, record, opts)
  def list(%module{} = manager, opts \\ []), do: module.list(manager, opts)
  def delete(%module{} = manager, ids, opts \\ []), do: module.delete(manager, List.wrap(ids), opts)

  @doc "Whether `manager` is a struct whose module implements this behaviour."
  @spec record_manager?(term()) :: boolean()
  def record_manager?(%module{}), do: BeamWeaver.Behaviour.implemented_by?(module, __MODULE__)
  def record_manager?(_other), do: false

  @doc """
  Returns the current wall-clock time in seconds, as a float.

  `update/3` rejects a `:time_at_least` option later than this time.
  """
  @spec get_time(term()) :: float()
  def get_time(_manager), do: System.system_time(:microsecond) / 1_000_000

  @doc """
  Upserts record keys with optional source/group IDs.

  Writes one `%Record{}` per key; the optional `:group_ids` list (one entry per
  key) sets each record's source id. Use `put/3` with explicit `%Record{}`
  structs when you need per-record hash metadata.
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
      |> Enum.sort_by(&{timestamp_value(&1.updated_at), &1.id})
      |> maybe_take(limit)
      |> Enum.map(& &1.id)
    end
  end

  @spec delete_keys(term(), [String.t()], keyword()) :: :ok | {:error, Error.t()}
  def delete_keys(manager, keys, opts \\ []), do: delete(manager, keys, opts)

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
