defmodule BeamWeaver.Memory.Ecto do
  @moduledoc """
  Ecto/Postgres implementation of `BeamWeaver.Memory.Store`.
  """

  @behaviour BeamWeaver.Memory.Store

  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Memory.GetOp
  alias BeamWeaver.Memory.Item
  alias BeamWeaver.Memory.ListNamespacesOp
  alias BeamWeaver.Memory.MatchCondition
  alias BeamWeaver.Memory.PutOp
  alias BeamWeaver.Memory.Query
  alias BeamWeaver.Memory.SearchOp

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            table: "beam_weaver_memory_items",
            refresh_on_read?: false,
            default_ttl: nil

  @type t :: %__MODULE__{
          repo: module(),
          query_module: module(),
          table: String.t(),
          refresh_on_read?: boolean(),
          default_ttl: number() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      query_module: Keyword.get(opts, :query_module, Ecto.Adapters.SQL),
      table: Keyword.get(opts, :table, "beam_weaver_memory_items"),
      refresh_on_read?: Keyword.get(opts, :refresh_on_read?, Keyword.get(opts, :refresh_on_read, false)),
      default_ttl: Keyword.get(opts, :default_ttl)
    }
  end

  @impl true
  def put(%__MODULE__{} = store, namespace, key, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    sql = """
    INSERT INTO #{store.table} (namespace, key, value, metadata, expires_at)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (namespace, key)
    DO UPDATE SET value = EXCLUDED.value,
                  metadata = EXCLUDED.metadata,
                  expires_at = EXCLUDED.expires_at,
                  updated_at = now()
    RETURNING namespace, key, value, metadata, created_at, updated_at, expires_at
    """

    ttl =
      case Keyword.get(opts, :ttl, :not_provided) do
        :not_provided -> store.default_ttl
        ttl -> ttl
      end

    params = [namespace, key, value, metadata, Query.expires_at(ttl)]

    case query(store, sql, params) do
      {:ok, %{rows: [row]}} -> {:ok, item_from_row(row)}
      error -> error
    end
  end

  @impl true
  def get(%__MODULE__{} = store, namespace, key) do
    sql = """
    SELECT namespace, key, value, metadata, created_at, updated_at, expires_at
    FROM #{store.table}
    WHERE namespace = $1 AND key = $2
    """

    case query(store, sql, [namespace, key]) do
      {:ok, %{rows: [row]}} ->
        item = item_from_row(row)

        if Query.expired?(item) do
          delete(store, namespace, key)
          :error
        else
          refresh_item(store, item)
        end

      {:ok, %{rows: []}} ->
        :error

      error ->
        error
    end
  end

  @impl true
  def delete(%__MODULE__{} = store, namespace, key) do
    case query(store, "DELETE FROM #{store.table} WHERE namespace = $1 AND key = $2", [
           namespace,
           key
         ]) do
      {:ok, _result} -> :ok
      error -> error
    end
  end

  @impl true
  def search(%__MODULE__{} = store, namespace, opts) do
    sql = """
    SELECT namespace, key, value, metadata, created_at, updated_at, expires_at
    FROM #{store.table}
    WHERE namespace[1:array_length($1::text[], 1)] = $1
    ORDER BY updated_at DESC
    """

    case query(store, sql, [namespace]) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(&item_from_row/1)
        |> Enum.reject(&Query.expired?/1)
        |> maybe_refresh_items(store)
        |> Query.search_items(namespace, opts)

      error ->
        error
    end
  end

  @impl true
  def list_namespaces(%__MODULE__{} = store, opts) do
    sql = """
    SELECT DISTINCT namespace
    FROM #{store.table}
    ORDER BY namespace ASC
    """

    case query(store, sql, []) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [namespace] -> namespace end)
        |> Query.list_namespaces(opts)

      error ->
        error
    end
  end

  @impl true
  def batch(%__MODULE__{} = store, ops) when is_list(ops) do
    Enum.map(ops, fn
      %GetOp{namespace: namespace, key: key} ->
        case get(store, namespace, key) do
          {:ok, item} -> item
          :error -> nil
          {:error, error} -> {:error, error}
        end

      %SearchOp{} = op ->
        search(store, op.namespace,
          filter: op.filter,
          limit: op.limit,
          offset: op.offset,
          query: op.query
        )

      %PutOp{namespace: namespace, key: key, value: nil} ->
        delete(store, namespace, key)
        nil

      %PutOp{} = op ->
        put(store, op.namespace, op.key, op.value,
          metadata: op.metadata,
          ttl: op.ttl
        )

        nil

      %ListNamespacesOp{} = op ->
        list_namespaces(store, list_namespace_opts(op))
    end)
  end

  def sweep_expired(%__MODULE__{} = store, _opts \\ []) do
    case query(
           store,
           "DELETE FROM #{store.table} WHERE expires_at IS NOT NULL AND expires_at <= now()",
           []
         ) do
      {:ok, result} -> {:ok, Map.get(result, :num_rows, 0)}
      error -> error
    end
  end

  @doc """
  Starts a caller-supervised TTL sweeper for this store.
  """
  @spec start_ttl_sweeper(t(), keyword()) :: GenServer.on_start()
  def start_ttl_sweeper(%__MODULE__{} = store, opts \\ []) do
    BeamWeaver.Memory.TTLSweeper.start_link(store, opts)
  end

  @doc """
  Stops a TTL sweeper started with `start_ttl_sweeper/2`.
  """
  @spec stop_ttl_sweeper(pid() | atom(), timeout()) :: :ok
  def stop_ttl_sweeper(server, timeout \\ 5_000) do
    BeamWeaver.Memory.TTLSweeper.stop(server, timeout)
  end

  defp item_from_row([namespace, key, value, metadata, created_at, updated_at]) do
    item_from_row([namespace, key, value, metadata, created_at, updated_at, nil])
  end

  defp item_from_row([namespace, key, value, metadata, created_at, updated_at, expires_at]) do
    %Item{
      namespace: namespace,
      key: key,
      value: value,
      metadata: metadata || %{},
      created_at: created_at,
      updated_at: updated_at,
      expires_at: expires_at
    }
  end

  defp list_namespace_opts(%ListNamespacesOp{} = op) do
    {prefix, suffix} =
      Enum.reduce(op.match_conditions || [], {[], []}, fn
        %MatchCondition{type: :prefix, path: path}, {_prefix, suffix} -> {path, suffix}
        %MatchCondition{type: "prefix", path: path}, {_prefix, suffix} -> {path, suffix}
        %MatchCondition{type: :suffix, path: path}, {prefix, _suffix} -> {prefix, path}
        %MatchCondition{type: "suffix", path: path}, {prefix, _suffix} -> {prefix, path}
      end)

    [
      prefix: prefix,
      suffix: suffix,
      max_depth: op.max_depth,
      limit: op.limit,
      offset: op.offset
    ]
  end

  defp query(%__MODULE__{} = store, sql, params) do
    AdapterError.query(store, sql, params,
      type: :memory_error,
      message: "memory adapter error"
    )
  end

  defp refresh_item(%__MODULE__{refresh_on_read?: false}, item), do: {:ok, item}
  defp refresh_item(%__MODULE__{default_ttl: nil}, item), do: {:ok, item}

  defp refresh_item(%__MODULE__{} = store, item) do
    expires_at = Query.expires_at(store.default_ttl)

    sql = """
    UPDATE #{store.table}
    SET expires_at = $3
    WHERE namespace = $1 AND key = $2
    """

    case query(store, sql, [item.namespace, item.key, expires_at]) do
      {:ok, _result} -> {:ok, %{item | expires_at: expires_at}}
      error -> error
    end
  end

  defp maybe_refresh_items(items, %__MODULE__{refresh_on_read?: false}), do: items
  defp maybe_refresh_items(items, %__MODULE__{default_ttl: nil}), do: items

  defp maybe_refresh_items(items, %__MODULE__{} = store) do
    Enum.map(items, fn item ->
      case refresh_item(store, item) do
        {:ok, refreshed} -> refreshed
        _error -> item
      end
    end)
  end
end
