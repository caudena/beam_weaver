defmodule BeamWeaver.Memory.Ecto do
  @moduledoc """
  Ecto/Postgres implementation of `BeamWeaver.Memory.Store`.

  ## Options

    * `:repo` - the Ecto repo (required)
    * `:table` - the table name, as given to the migration
    * `:prefix` - the Postgres schema that holds the table, as given to the
      migration's `prefix:`
    * `:default_ttl` - lifetime in minutes of records put without `ttl:`;
      `nil` (the default) keeps them until they are deleted
    * `:refresh_ttl` - whether reading a record with `get` or `search` starts
      its lifetime again (default `false`)

  `BeamWeaver.Memory.ETS` takes the same `:default_ttl` and `:refresh_ttl`.
  """

  @behaviour BeamWeaver.Memory.Store

  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Memory.Item
  alias BeamWeaver.Memory.Query
  alias BeamWeaver.Migrations.Postgres.Util

  @columns "namespace, key, value, metadata, created_at, updated_at, expires_at, ttl_minutes"

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            table: "beam_weaver_memory_items",
            prefix: nil,
            default_ttl: nil,
            refresh_ttl: false

  @type t :: %__MODULE__{
          repo: module(),
          query_module: module(),
          table: String.t(),
          prefix: String.t() | nil,
          default_ttl: number() | nil,
          refresh_ttl: boolean()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      opts
      |> Keyword.validate!([:repo, :query_module, :table, :prefix, :default_ttl, :refresh_ttl])
      |> Keyword.update(:refresh_ttl, false, &Query.refresh_ttl_option!/1)

    struct!(%__MODULE__{repo: Keyword.fetch!(opts, :repo)}, opts)
  end

  @impl true
  def put(%__MODULE__{} = store, namespace, key, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    ttl = with :not_provided <- Keyword.get(opts, :ttl, :not_provided), do: store.default_ttl

    sql = """
    INSERT INTO #{table(store)} (namespace, key, value, metadata, expires_at, ttl_minutes)
    VALUES ($1, $2, $3, $4, $5, $6)
    ON CONFLICT (namespace, key)
    DO UPDATE SET value = EXCLUDED.value,
                  metadata = EXCLUDED.metadata,
                  expires_at = EXCLUDED.expires_at,
                  ttl_minutes = EXCLUDED.ttl_minutes,
                  updated_at = now()
    RETURNING #{@columns}
    """

    with {:ok, %{rows: [row]}} <- query(store, sql, [namespace, key, value, metadata, Query.expires_at(ttl), ttl]),
         do: {:ok, item_from_row(row)}
  end

  @impl true
  def get(%__MODULE__{} = store, namespace, key), do: get_item(store, namespace, key, store.refresh_ttl)

  defp get_item(store, namespace, key, refresh_ttl) do
    sql = "SELECT #{@columns} FROM #{table(store)} WHERE namespace = $1 AND key = $2"

    case query(store, sql, [namespace, key]) do
      {:ok, %{rows: [row]}} ->
        item = item_from_row(row)

        cond do
          Query.expired?(item) ->
            delete_expired(store, namespace, key)
            :error

          refresh_ttl ->
            refresh_item(store, item)

          true ->
            {:ok, item}
        end

      {:ok, %{rows: []}} ->
        :error

      error ->
        error
    end
  end

  @impl true
  def delete(%__MODULE__{} = store, namespace, key) do
    with {:ok, _result} <-
           query(store, "DELETE FROM #{table(store)} WHERE namespace = $1 AND key = $2", [namespace, key]),
         do: :ok
  end

  # A record put again since it was read is no longer expired, and stays.
  defp delete_expired(store, namespace, key) do
    sql = "DELETE FROM #{table(store)} WHERE namespace = $1 AND key = $2 AND expires_at <= now()"
    query(store, sql, [namespace, key])
  end

  @impl true
  def search(%__MODULE__{} = store, namespace, opts) do
    sql = """
    SELECT #{@columns}
    FROM #{table(store)}
    WHERE cardinality($1::text[]) = 0 OR namespace[1:cardinality($1::text[])] = $1
    ORDER BY updated_at DESC
    """

    with {:ok, %{rows: rows}} <- query(store, sql, [namespace]) do
      rows
      |> Enum.map(&item_from_row/1)
      |> Enum.reject(&Query.expired?/1)
      |> Query.search_items(namespace, opts)
      |> maybe_refresh_items(store, Query.refresh_ttl?(store, Keyword.get(opts, :refresh_ttl)))
    end
  end

  @impl true
  def list_namespaces(%__MODULE__{} = store, opts) do
    sql = """
    SELECT DISTINCT namespace
    FROM #{table(store)}
    WHERE expires_at IS NULL OR expires_at > now()
    ORDER BY namespace ASC
    """

    with {:ok, %{rows: rows}} <- query(store, sql, []),
         do: rows |> Enum.map(fn [namespace] -> namespace end) |> Query.list_namespaces(opts)
  end

  @impl true
  def batch(%__MODULE__{} = store, ops) when is_list(ops), do: Query.batch(store, ops, &get_item(store, &1, &2, &3))

  def sweep_expired(%__MODULE__{} = store, _opts \\ []) do
    deleted_rows(query(store, "DELETE FROM #{table(store)} WHERE expires_at IS NOT NULL AND expires_at <= now()", []))
  end

  @doc """
  Deletes old records; `BeamWeaver.Memory.prune/2` calls it.

  `namespace:` limits it to the records of exactly that namespace.
  `older_than:` (a `DateTime`) or `max_age_ms:` deletes the records last
  updated at or before that time, and `max_entries:` keeps only that many of
  the most recently updated records. Returns how many records were deleted.
  """
  @spec prune(t(), keyword()) :: {:ok, non_neg_integer()} | {:error, BeamWeaver.Core.Error.t()}
  def prune(%__MODULE__{} = store, opts \\ []) do
    namespace = Keyword.get(opts, :namespace)

    with {:ok, aged} <- prune_older_than(store, namespace, Query.prune_cutoff(opts)),
         {:ok, excess} <- prune_to_limit(store, namespace, Keyword.get(opts, :max_entries)) do
      {:ok, aged + excess}
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

  defp prune_older_than(_store, _namespace, nil), do: {:ok, 0}

  defp prune_older_than(store, namespace, cutoff) do
    sql = """
    DELETE FROM #{table(store)}
    WHERE ($1::text[] IS NULL OR namespace = $1) AND updated_at <= $2
    """

    deleted_rows(query(store, sql, [namespace, cutoff]))
  end

  defp prune_to_limit(store, namespace, max_entries) when is_integer(max_entries) and max_entries >= 0 do
    sql = """
    DELETE FROM #{table(store)}
    WHERE (namespace, key) IN (
      SELECT namespace, key
      FROM #{table(store)}
      WHERE $1::text[] IS NULL OR namespace = $1
      ORDER BY updated_at DESC, namespace, key
      OFFSET $2
    )
    """

    deleted_rows(query(store, sql, [namespace, max_entries]))
  end

  defp prune_to_limit(_store, _namespace, _max_entries), do: {:ok, 0}

  defp deleted_rows({:ok, result}), do: {:ok, Map.get(result, :num_rows, 0)}
  defp deleted_rows(error), do: error

  defp item_from_row([namespace, key, value, metadata, created_at, updated_at, expires_at, ttl]) do
    %Item{
      namespace: namespace,
      key: key,
      value: value,
      metadata: metadata || %{},
      created_at: created_at,
      updated_at: updated_at,
      expires_at: expires_at,
      ttl: ttl
    }
  end

  defp table(%__MODULE__{} = store), do: Util.qualify(store.prefix, store.table)

  defp query(%__MODULE__{} = store, sql, params),
    do: AdapterError.query(store, sql, params, :memory_error, "memory adapter error")

  # Starts a record's lifetime again from now; records without one keep none.
  # The lifetime is the one the row has when it is updated, so a record put
  # again since it was read keeps its own.
  defp refresh_item(_store, %{ttl: nil} = item), do: {:ok, item}

  defp refresh_item(%__MODULE__{} = store, item) do
    sql = """
    UPDATE #{table(store)}
    SET expires_at = $3::timestamptz + ttl_minutes * interval '1 minute'
    WHERE namespace = $1 AND key = $2 AND ttl_minutes IS NOT NULL
    RETURNING expires_at
    """

    case query(store, sql, [item.namespace, item.key, DateTime.utc_now()]) do
      {:ok, %{rows: [[expires_at]]}} -> {:ok, %{item | expires_at: expires_at}}
      {:ok, _result} -> {:ok, item}
      error -> error
    end
  end

  defp maybe_refresh_items(items, _store, false), do: items

  defp maybe_refresh_items(items, store, true) do
    Enum.map(items, fn item ->
      case refresh_item(store, item) do
        {:ok, refreshed} -> refreshed
        _error -> item
      end
    end)
  end
end
