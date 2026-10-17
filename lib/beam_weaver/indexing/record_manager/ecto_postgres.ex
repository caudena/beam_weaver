defmodule BeamWeaver.Indexing.RecordManager.EctoPostgres do
  @moduledoc """
  SQL-boundary Ecto/Postgres indexing record manager.

  Runtime indexing depends on the `RecordManager` behaviour. This adapter keeps
  Postgres-specific setup and SQL contained at the boundary.
  """

  use BeamWeaver.Indexing.RecordManager

  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Indexing.Record
  alias BeamWeaver.Indexing.RecordManager

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            table: "beam_weaver_indexing_records",
            prefix: nil,
            namespace: :default

  def new(opts) do
    %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      query_module: Keyword.get(opts, :query_module, Ecto.Adapters.SQL),
      table: Keyword.get(opts, :table, "beam_weaver_indexing_records"),
      prefix: Keyword.get(opts, :prefix),
      namespace: Keyword.get(opts, :namespace, :default)
    }
  end

  @impl true
  def get(%__MODULE__{} = manager, id, opts) do
    namespace = namespace(manager, opts)

    sql = """
    SELECT id, source_id, hash, metadata, updated_at
    FROM #{table(manager)}
    WHERE namespace = $1 AND id = $2
    LIMIT 1
    """

    with {:ok, result} <- query(manager, sql, [namespace, to_string(id)]) do
      case rows_from_result(result) do
        [] -> {:ok, nil}
        [row | _] -> {:ok, record_from_row(row, namespace)}
      end
    end
  end

  @impl true
  def put(%__MODULE__{} = manager, %Record{} = record, opts) do
    namespace = to_string(Keyword.get(opts, :namespace, RecordManager.record_namespace(manager, record.namespace)))

    sql = """
    INSERT INTO #{table(manager)} (namespace, id, source_id, hash, metadata, updated_at)
    VALUES ($1, $2, $3, $4, $5, now())
    ON CONFLICT (namespace, id)
    DO UPDATE SET source_id = EXCLUDED.source_id,
                  hash = EXCLUDED.hash,
                  metadata = EXCLUDED.metadata,
                  updated_at = now()
    """

    params = [
      namespace,
      to_string(record.id),
      to_string(record.source_id),
      to_string(record.hash),
      record.metadata || %{}
    ]

    with {:ok, _result} <- query(manager, sql, params), do: :ok
  end

  @impl true
  def list(%__MODULE__{} = manager, opts) do
    namespace = namespace(manager, opts)
    source_ids = opts |> Keyword.get(:source_ids) |> RecordManager.normalize_source_ids()

    {source_sql, params} =
      case source_ids do
        nil -> {"", [namespace]}
        ids -> {" AND source_id = ANY($2)", [namespace, ids]}
      end

    sql = """
    SELECT id, source_id, hash, metadata, updated_at
    FROM #{table(manager)}
    WHERE namespace = $1#{source_sql}
    ORDER BY updated_at ASC, id ASC
    """

    with {:ok, result} <- query(manager, sql, params),
         do: {:ok, result |> rows_from_result() |> Enum.map(&record_from_row(&1, namespace))}
  end

  @impl true
  def delete(%__MODULE__{} = manager, ids, opts) do
    params = [namespace(manager, opts), Enum.map(ids, &to_string/1)]

    with {:ok, _result} <- query(manager, "DELETE FROM #{table(manager)} WHERE namespace = $1 AND id = ANY($2)", params),
         do: :ok
  end

  # The table, in the Postgres schema `prefix:` names, quoted as the migration quotes it.
  defp table(%__MODULE__{} = manager), do: BeamWeaver.Migrations.Postgres.Util.qualify(manager.prefix, manager.table)

  defp query(%__MODULE__{} = manager, sql, params),
    do: AdapterError.query(manager, sql, params, :record_manager_error, "record manager adapter error")

  defp rows_from_result(%{columns: columns, rows: rows}), do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))

  defp record_from_row(row, namespace) do
    %Record{
      id: row["id"],
      source_id: row["source_id"],
      hash: row["hash"],
      metadata: row["metadata"] || %{},
      namespace: namespace,
      updated_at: normalize_datetime(row["updated_at"])
    }
  end

  defp normalize_datetime(%DateTime{} = datetime), do: datetime

  defp normalize_datetime(%NaiveDateTime{} = datetime),
    do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp normalize_datetime(_value), do: nil

  defp namespace(manager, opts), do: to_string(Keyword.get(opts, :namespace, manager.namespace))
end
