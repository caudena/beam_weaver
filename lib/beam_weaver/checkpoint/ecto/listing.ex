defmodule BeamWeaver.Checkpoint.Ecto.Listing do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Ecto.Rows
  alias BeamWeaver.Checkpoint.Ecto.SQL

  def get_tuple(saver, config) do
    configurable = Checkpoint.configurable(config)

    with thread_id when is_binary(thread_id) <- configurable["thread_id"],
         namespace <- Map.get(configurable, "checkpoint_ns", ""),
         checkpoint_id <- configurable["checkpoint_id"],
         {:ok, %{rows: [row]}} <-
           SQL.query(saver, get_tuple_sql(saver), [thread_id, namespace, checkpoint_id]) do
      Rows.tuple_from_row(saver, row)
    else
      _other -> nil
    end
  end

  def list(saver, config, opts) do
    configurable = if config, do: Checkpoint.configurable(config), else: %{}

    filter =
      (Keyword.get(opts, :filter, %{}) || %{})
      |> Config.stringify_keys()
      |> dump_filter(saver)

    before_id = Config.before_checkpoint_id(Keyword.get(opts, :before))
    limit = Keyword.get(opts, :limit)

    {clauses, params} =
      {[], []}
      |> maybe_where("thread_id", Map.get(configurable, "thread_id"))
      |> maybe_where("checkpoint_ns", Map.get(configurable, "checkpoint_ns"))
      |> maybe_before(before_id)
      |> maybe_filter(filter)

    where = if clauses == [], do: "TRUE", else: Enum.join(clauses, " AND ")
    limit_sql = if is_integer(limit), do: "LIMIT #{limit}", else: ""

    sql = list_sql(saver, where, limit_sql)

    case SQL.query(saver, sql, params) do
      {:ok, %{rows: rows}} -> Rows.tuples_from_rows(saver, rows)
      _error -> []
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
    sql = """
    SELECT checkpoint_id
    FROM #{saver.checkpoints_table}
    WHERE thread_id = $1 AND checkpoint_ns = $2
    ORDER BY checkpoint_id DESC
    LIMIT 1
    """

    case SQL.query(saver, sql, [thread_id, namespace]) do
      {:ok, %{rows: [[checkpoint_id]]}} -> checkpoint_id
      _other -> nil
    end
  end

  defp get_tuple_sql(saver) do
    """
    WITH selected AS (
      SELECT thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata
      FROM #{saver.checkpoints_table}
      WHERE thread_id = $1
        AND checkpoint_ns = $2
        AND ($3::text IS NULL OR checkpoint_id = $3)
      ORDER BY checkpoint_id DESC
      LIMIT 1
    )
    #{selected_rows_with_writes_sql(saver)}
    """
  end

  defp list_sql(saver, where, limit_sql) do
    """
    WITH selected AS (
      SELECT thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata
      FROM #{saver.checkpoints_table}
      WHERE #{where}
      ORDER BY checkpoint_id DESC
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
    ORDER BY selected.checkpoint_id DESC
    """
  end

  defp maybe_where({clauses, params}, _field, nil), do: {clauses, params}

  defp maybe_where({clauses, params}, field, value) do
    position = length(params) + 1
    {clauses ++ ["#{field} = $#{position}"], params ++ [value]}
  end

  defp maybe_before({clauses, params}, nil), do: {clauses, params}

  defp maybe_before({clauses, params}, checkpoint_id) do
    position = length(params) + 1
    {clauses ++ ["checkpoint_id < $#{position}"], params ++ [checkpoint_id]}
  end

  defp maybe_filter({clauses, params}, filter) when filter in [%{}, nil], do: {clauses, params}

  defp maybe_filter({clauses, params}, filter) do
    position = length(params) + 1
    {clauses ++ ["metadata @> $#{position}"], params ++ [filter]}
  end

  defp dump_filter(filter, saver) do
    case saver.__struct__.dump_json_value(saver, filter) do
      {:ok, encoded} -> encoded
      {:error, _error} -> filter
    end
  end
end
