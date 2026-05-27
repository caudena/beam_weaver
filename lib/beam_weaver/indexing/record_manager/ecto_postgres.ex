defmodule BeamWeaver.Indexing.RecordManager.EctoPostgres do
  @moduledoc """
  SQL-boundary Ecto/Postgres indexing record manager.

  Runtime indexing depends on the `RecordManager` behaviour. This adapter keeps
  Postgres-specific setup and SQL contained at the boundary.
  """

  use BeamWeaver.Indexing.RecordManager

  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Indexing.Record

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            table: "beam_weaver_indexing_records",
            namespace: :default

  def new(opts) do
    %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      query_module: Keyword.get(opts, :query_module, Ecto.Adapters.SQL),
      table: Keyword.get(opts, :table, "beam_weaver_indexing_records"),
      namespace: Keyword.get(opts, :namespace, :default)
    }
  end

  @impl true
  def get(%__MODULE__{} = manager, id, opts) do
    namespace = namespace(manager, opts)

    sql = """
    SELECT id, source_id, hash, metadata, updated_at
    FROM #{manager.table}
    WHERE namespace = $1 AND id = $2
    LIMIT 1
    """

    case query(manager, sql, [namespace, to_string(id)]) do
      {:ok, result} ->
        case rows_from_result(result) do
          [] -> {:ok, nil}
          [row | _] -> {:ok, record_from_row(row, namespace)}
        end

      {:error, error} ->
        {:error, normalize_error(error)}
    end
  end

  @impl true
  def put(%__MODULE__{} = manager, %Record{} = record, opts) do
    namespace = namespace(manager, opts, record.namespace)

    sql = """
    INSERT INTO #{manager.table} (namespace, id, source_id, hash, metadata, updated_at)
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

    case query(manager, sql, params) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  @impl true
  def list(%__MODULE__{} = manager, opts) do
    namespace = namespace(manager, opts)
    source_ids = opts |> Keyword.get(:source_ids) |> normalize_source_ids()

    {source_sql, params} =
      case source_ids do
        nil -> {"", [namespace]}
        ids -> {" AND source_id = ANY($2)", [namespace, ids]}
      end

    sql = """
    SELECT id, source_id, hash, metadata, updated_at
    FROM #{manager.table}
    WHERE namespace = $1#{source_sql}
    ORDER BY updated_at ASC, id ASC
    """

    case query(manager, sql, params) do
      {:ok, result} ->
        {:ok, result |> rows_from_result() |> Enum.map(&record_from_row(&1, namespace))}

      {:error, error} ->
        {:error, normalize_error(error)}
    end
  end

  @impl true
  def delete(%__MODULE__{} = manager, ids, opts) do
    namespace = namespace(manager, opts)

    case query(manager, "DELETE FROM #{manager.table} WHERE namespace = $1 AND id = ANY($2)", [
           namespace,
           Enum.map(ids, &to_string/1)
         ]) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp query(%__MODULE__{} = manager, sql, params) do
    AdapterError.query(manager, sql, params,
      type: :record_manager_error,
      message: "record manager adapter error"
    )
  end

  defp rows_from_result(%{columns: columns, rows: rows}) do
    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp rows_from_result(%{rows: rows}), do: Enum.map(rows, &row_map/1)
  defp rows_from_result(rows) when is_list(rows), do: Enum.map(rows, &row_map/1)
  defp rows_from_result(_result), do: []

  defp row_map(%{} = row), do: row

  defp row_map([id, source_id, hash, metadata, updated_at]) do
    %{
      "id" => id,
      "source_id" => source_id,
      "hash" => hash,
      "metadata" => metadata,
      "updated_at" => updated_at
    }
  end

  defp row_map(row), do: %{"row" => row}

  defp record_from_row(row, namespace) do
    %Record{
      id: fetch(row, ["id", :id]),
      source_id: fetch(row, ["source_id", :source_id]),
      hash: fetch(row, ["hash", :hash]),
      metadata: fetch(row, ["metadata", :metadata]) || %{},
      namespace: namespace,
      updated_at: normalize_datetime(fetch(row, ["updated_at", :updated_at]))
    }
  end

  defp fetch(row, keys), do: Enum.find_value(keys, &Map.get(row, &1))

  defp normalize_datetime(%DateTime{} = datetime), do: datetime

  defp normalize_datetime(%NaiveDateTime{} = datetime),
    do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp normalize_datetime(_value), do: nil

  defp namespace(manager, opts, record_namespace \\ nil) do
    Keyword.get(opts, :namespace, record_namespace(manager, record_namespace))
    |> to_string()
  end

  defp record_namespace(manager, nil), do: manager.namespace
  defp record_namespace(manager, :default), do: manager.namespace
  defp record_namespace(manager, "default"), do: manager.namespace
  defp record_namespace(_manager, namespace), do: namespace

  defp normalize_source_ids(nil), do: nil
  defp normalize_source_ids(source_ids), do: source_ids |> List.wrap() |> Enum.map(&to_string/1)

  defp normalize_error(%Error{} = error), do: error
end
