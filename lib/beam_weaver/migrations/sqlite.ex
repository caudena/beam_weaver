defmodule BeamWeaver.Migrations.SQLite do
  @moduledoc false

  use Ecto.Migration

  @current_version 2

  def current_version(opts \\ []) do
    checkpoint_spec!(opts)
    @current_version
  end

  def migrated_version(opts \\ []) do
    table = checkpoint_spec!(opts).checkpoints_table

    case table_columns(repo_for(opts), table) do
      [] -> 0
      columns -> if "commit_order" in columns, do: 2, else: 1
    end
  end

  def up(opts \\ []) do
    spec = checkpoint_spec!(opts)
    current = migrated_version(Keyword.put(opts, :adapter, :checkpoint))
    target = Keyword.get(opts, :version, @current_version)

    if current == 0 and target >= 1, do: create_initial(spec)
    if current < 2 and target >= 2, do: add_ordering(spec)
    :ok
  end

  def down(opts \\ []) do
    spec = checkpoint_spec!(opts)
    current = migrated_version(Keyword.put(opts, :adapter, :checkpoint))
    target = Keyword.get(opts, :version, 1)

    if current >= 2 and target <= 2, do: remove_ordering(spec)
    if current >= 1 and target <= 1, do: drop_initial(spec)
    :ok
  end

  def verify_migrated!(opts \\ []) do
    case migrated_version(opts) do
      @current_version ->
        :ok

      0 ->
        raise RuntimeError,
              "BeamWeaver checkpoint migrations have not been run for the SQLite repository"

      version ->
        raise RuntimeError,
              "BeamWeaver checkpoint migrations are outdated for the SQLite repository: " <>
                "found #{version}, expected #{@current_version}"
    end
  end

  defp create_initial(spec) do
    checkpoints = quote_name(spec.checkpoints_table)
    writes = quote_name(spec.writes_table)

    execute("""
    CREATE TABLE IF NOT EXISTS #{checkpoints} (
      thread_id TEXT NOT NULL,
      checkpoint_ns TEXT NOT NULL DEFAULT '',
      checkpoint_id TEXT NOT NULL,
      parent_checkpoint_id TEXT,
      checkpoint TEXT NOT NULL,
      metadata TEXT NOT NULL DEFAULT '{}',
      inserted_at TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW')),
      PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id)
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{writes} (
      thread_id TEXT NOT NULL,
      checkpoint_ns TEXT NOT NULL DEFAULT '',
      checkpoint_id TEXT NOT NULL,
      task_id TEXT NOT NULL,
      write_index INTEGER NOT NULL,
      channel TEXT NOT NULL,
      value TEXT NOT NULL,
      task_path TEXT NOT NULL DEFAULT '',
      inserted_at TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW')),
      PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id, task_id, write_index)
    )
    """)

    create_indexes(spec)
  end

  defp drop_initial(spec) do
    execute("DROP TABLE IF EXISTS #{quote_name(spec.writes_table)}")
    execute("DROP TABLE IF EXISTS #{quote_name(spec.checkpoints_table)}")
  end

  defp add_ordering(spec) do
    rebuild_checkpoints(spec, true, fn source ->
      """
      SELECT thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata,
             ROW_NUMBER() OVER (
               PARTITION BY thread_id, checkpoint_ns
               ORDER BY inserted_at, checkpoint_id
             ),
             inserted_at
      FROM #{source}
      """
    end)
  end

  defp remove_ordering(spec) do
    rebuild_checkpoints(spec, false, fn source ->
      """
      SELECT thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata,
             inserted_at
      FROM #{source}
      """
    end)
  end

  defp rebuild_checkpoints(spec, ordering?, select_sql) do
    table = quote_name(spec.checkpoints_table)
    temporary = quote_name(spec.checkpoints_table <> "__beam_weaver_rebuild")
    ordering_column = if ordering?, do: "commit_order INTEGER NOT NULL,", else: ""
    ordering_name = if ordering?, do: "commit_order,", else: ""

    execute("DROP TABLE IF EXISTS #{temporary}")

    execute("""
    CREATE TABLE #{temporary} (
      thread_id TEXT NOT NULL,
      checkpoint_ns TEXT NOT NULL DEFAULT '',
      checkpoint_id TEXT NOT NULL,
      parent_checkpoint_id TEXT,
      checkpoint TEXT NOT NULL,
      metadata TEXT NOT NULL DEFAULT '{}',
      #{ordering_column}
      inserted_at TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW')),
      PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id)
    )
    """)

    execute("""
    INSERT INTO #{temporary}
      (thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata,
       #{ordering_name} inserted_at)
    #{select_sql.(table)}
    """)

    execute("DROP TABLE #{table}")
    execute("ALTER TABLE #{temporary} RENAME TO #{quote_name(spec.checkpoints_table)}")
    create_indexes(spec, ordering?)
  end

  defp create_indexes(spec, ordering? \\ false) do
    checkpoints = quote_name(spec.checkpoints_table)

    execute("""
    CREATE INDEX IF NOT EXISTS #{index_name(spec.checkpoints_table, "thread_idx")}
    ON #{checkpoints} (thread_id, checkpoint_ns, checkpoint_id DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{index_name(spec.checkpoints_table, "metadata_run_id_idx")}
    ON #{checkpoints} (json_extract(metadata, '$.run_id'))
    """)

    if ordering? do
      execute("""
      CREATE UNIQUE INDEX IF NOT EXISTS #{index_name(spec.checkpoints_table, "commit_order_idx")}
      ON #{checkpoints} (thread_id, checkpoint_ns, commit_order)
      """)
    end
  end

  defp checkpoint_spec!(opts) do
    reject_prefix!(opts)

    selector = Keyword.get(opts, :adapters, Keyword.get(opts, :adapter, [:checkpoint]))

    case normalize_selector(selector) do
      [{:checkpoint, adapter_opts}] ->
        %{
          checkpoints_table:
            Keyword.get(
              adapter_opts,
              :checkpoints_table,
              Keyword.get(opts, :checkpoints_table, "beam_weaver_checkpoints")
            ),
          writes_table:
            Keyword.get(
              adapter_opts,
              :writes_table,
              Keyword.get(opts, :writes_table, "beam_weaver_checkpoint_writes")
            )
        }

      _other ->
        raise ArgumentError, "SQLite migrations currently support only the :checkpoint adapter"
    end
  end

  defp normalize_selector(:checkpoint), do: [{:checkpoint, []}]
  defp normalize_selector([:checkpoint]), do: [{:checkpoint, []}]
  defp normalize_selector({:checkpoint, opts}), do: [{:checkpoint, opts}]
  defp normalize_selector([{:checkpoint, opts}]), do: [{:checkpoint, opts}]
  defp normalize_selector(other), do: List.wrap(other)

  defp reject_prefix!(opts) do
    if Keyword.get(opts, :prefix) not in [nil, false, "", "main"] do
      raise ArgumentError, "SQLite checkpoint migrations do not support prefixes"
    end
  end

  defp table_columns(repo, table) do
    case Ecto.Adapters.SQL.query(repo, "PRAGMA table_info(#{quote_name(table)})", [], log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &Enum.at(&1, 1))
      _other -> []
    end
  end

  defp repo_for(opts), do: Keyword.get_lazy(opts, :repo, &repo/0)

  defp index_name(table, suffix), do: quote_name("#{table}_#{suffix}")

  defp quote_name(name) do
    escaped = name |> to_string() |> String.replace("\"", "\"\"")
    ~s("#{escaped}")
  end
end
