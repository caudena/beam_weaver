defmodule BeamWeaver.Checkpoint.Ecto.Listing do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Ecto.Rows
  alias BeamWeaver.Checkpoint.Ecto.SQL
  alias BeamWeaver.Core.Error

  def get_tuple(saver, config) do
    case fetch_tuple(saver, config) do
      {:ok, tuple} -> tuple
      {:error, error} -> raise_read_error!(error)
    end
  end

  def fetch_tuple(saver, config) do
    configurable = Checkpoint.configurable(config)

    case configurable["thread_id"] do
      thread_id when is_binary(thread_id) ->
        namespace = Map.get(configurable, "checkpoint_ns", "")
        checkpoint_id = configurable["checkpoint_id"]

        case SQL.query(saver, get_tuple_sql(saver), [thread_id, namespace, checkpoint_id]) do
          {:ok, %{rows: [row]}} -> {:ok, Rows.tuple_from_row(saver, row)}
          {:ok, %{rows: []}} -> {:ok, nil}
          {:error, _error} = error -> error
        end

      _other ->
        {:ok, nil}
    end
  end

  def list(saver, config, opts) do
    case list_result(saver, config, opts) do
      {:ok, tuples} -> tuples
      {:error, error} -> raise_read_error!(error)
    end
  end

  def list_result(saver, config, opts) do
    configurable = if config, do: Checkpoint.configurable(config), else: %{}

    with {:ok, filter} <-
           dump_filter(saver, Config.stringify_keys(Keyword.get(opts, :filter, %{}) || %{})) do
      before = Keyword.get(opts, :before)
      limit = Keyword.get(opts, :limit)

      with {:ok, before_order} <- before_commit_order(saver, before) do
        {clauses, params} =
          {[], []}
          |> maybe_where("thread_id", Map.get(configurable, "thread_id"))
          |> maybe_where("checkpoint_ns", Map.get(configurable, "checkpoint_ns"))
          |> maybe_before(before_order)
          |> maybe_filter(filter)

        where = if clauses == [], do: "TRUE", else: Enum.join(clauses, " AND ")
        limit_sql = if is_integer(limit), do: "LIMIT #{limit}", else: ""

        case SQL.query(saver, list_sql(saver, where, limit_sql), params) do
          {:ok, %{rows: rows}} -> {:ok, Rows.tuples_from_rows(saver, rows)}
          {:error, _error} = error -> error
        end
      end
    end
  end

  def resolve_checkpoint_id(_saver, _thread_id, _namespace, checkpoint_id)
      when is_binary(checkpoint_id),
      do: {:ok, checkpoint_id}

  def resolve_checkpoint_id(saver, thread_id, namespace, _checkpoint_id) do
    case latest_checkpoint_id(saver, thread_id, namespace) do
      nil -> :error
      checkpoint_id -> {:ok, checkpoint_id}
    end
  end

  def latest_checkpoint_id(saver, thread_id, namespace) do
    case latest_checkpoint_id_result(saver, thread_id, namespace) do
      {:ok, checkpoint_id} -> checkpoint_id
      {:error, error} -> raise_read_error!(error)
    end
  end

  def latest_checkpoint_id_result(saver, thread_id, namespace) do
    sql = """
    SELECT checkpoint_id
    FROM #{saver.checkpoints_table}
    WHERE thread_id = $1 AND checkpoint_ns = $2
    ORDER BY commit_order DESC
    LIMIT 1
    """

    case SQL.query(saver, sql, [thread_id, namespace]) do
      {:ok, %{rows: [[checkpoint_id]]}} -> {:ok, checkpoint_id}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, _error} = error -> error
    end
  end

  defp get_tuple_sql(saver) do
    """
    WITH selected AS (
      SELECT thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata,
             commit_order
      FROM #{saver.checkpoints_table}
      WHERE thread_id = $1
        AND checkpoint_ns = $2
        AND ($3::text IS NULL OR checkpoint_id = $3)
      ORDER BY commit_order DESC
      LIMIT 1
    )
    #{selected_rows_with_writes_sql(saver)}
    """
  end

  defp list_sql(saver, where, limit_sql) do
    """
    WITH selected AS (
      SELECT thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata,
             commit_order
      FROM #{saver.checkpoints_table}
      WHERE #{where}
      ORDER BY commit_order DESC
      #{limit_sql}
    )
    #{selected_rows_with_writes_sql(saver)}
    """
  end

  defp selected_rows_with_writes_sql(saver) do
    """
    SELECT selected.thread_id,
           selected.checkpoint_ns,
           selected.checkpoint_id,
           selected.parent_checkpoint_id,
           selected.checkpoint,
           selected.metadata,
           selected.commit_order,
           COALESCE(
             (
               SELECT jsonb_agg(
                        jsonb_build_array(
                          writes.thread_id,
                          writes.checkpoint_ns,
                          writes.checkpoint_id,
                          writes.task_id,
                          writes.write_index,
                          writes.channel,
                          writes.value,
                          writes.task_path
                        )
                        ORDER BY writes.thread_id ASC,
                                 writes.checkpoint_ns ASC,
                                 writes.checkpoint_id ASC,
                                 writes.task_id ASC,
                                 writes.write_index ASC
                      )
               FROM #{saver.writes_table} AS writes
               WHERE writes.thread_id = selected.thread_id
                 AND writes.checkpoint_ns = selected.checkpoint_ns
                 AND (
                   writes.checkpoint_id = selected.checkpoint_id
                   OR (
                     selected.parent_checkpoint_id IS NOT NULL
                     AND writes.checkpoint_id = selected.parent_checkpoint_id
                   )
                 )
             ),
             '[]'::jsonb
           ) AS pending_write_rows
    FROM selected
    ORDER BY selected.commit_order DESC
    """
  end

  defp maybe_where({clauses, params}, _field, nil), do: {clauses, params}

  defp maybe_where({clauses, params}, field, value) do
    position = length(params) + 1
    {clauses ++ ["#{field} = $#{position}"], params ++ [value]}
  end

  defp maybe_before({clauses, params}, nil), do: {clauses, params}

  defp maybe_before({clauses, params}, commit_order) do
    position = length(params) + 1
    {clauses ++ ["commit_order < $#{position}"], params ++ [commit_order]}
  end

  defp before_commit_order(_saver, nil), do: {:ok, nil}

  defp before_commit_order(saver, before) do
    configurable = Checkpoint.configurable(before)

    sql = """
    SELECT commit_order
    FROM #{saver.checkpoints_table}
    WHERE thread_id = $1 AND checkpoint_ns = $2 AND checkpoint_id = $3
    """

    case SQL.query(saver, sql, [
           configurable["thread_id"],
           Map.get(configurable, "checkpoint_ns", ""),
           configurable["checkpoint_id"]
         ]) do
      {:ok, %{rows: [[order]]}} -> {:ok, order}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_filter({clauses, params}, filter) when filter in [%{}, nil], do: {clauses, params}

  defp maybe_filter({clauses, params}, filter) do
    position = length(params) + 1
    {clauses ++ ["metadata @> $#{position}"], params ++ [filter]}
  end

  defp dump_filter(saver, filter), do: saver.__struct__.dump_json_value(saver, filter)

  defp raise_read_error!(%Error{} = error), do: raise(RuntimeError, error.message)
  defp raise_read_error!(error), do: raise(RuntimeError, inspect(error))
end
