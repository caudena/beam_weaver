defmodule BeamWeaver.Test.SQLiteRepo do
  use Ecto.Repo,
    otp_app: :beam_weaver,
    adapter: Ecto.Adapters.SQLite3
end

defmodule BeamWeaver.Test.LiveSQLiteMigration do
  use Ecto.Migration

  def up do
    BeamWeaver.Migrations.up(:persistent_term.get({__MODULE__, :opts}))
  end

  def down do
    BeamWeaver.Migrations.down(:persistent_term.get({__MODULE__, :opts}))
  end
end

defmodule BeamWeaver.Test.LiveSQLite do
  @moduledoc false

  alias BeamWeaver.Test.LiveSQLiteMigration
  alias BeamWeaver.Test.SQLiteRepo

  def start_repo do
    Application.put_env(:beam_weaver, SQLiteRepo,
      database: database_path(),
      pool_size: 1,
      stacktrace: true,
      show_sensitive_data_on_connection_error: false
    )

    case Process.whereis(SQLiteRepo) do
      nil ->
        case SQLiteRepo.start_link() do
          {:ok, pid} = ok ->
            Process.unlink(pid)
            ok

          other ->
            other
        end

      pid ->
        {:ok, pid}
    end
  end

  def unique_table(prefix) do
    suffix =
      :crypto.strong_rand_bytes(5)
      |> Base.encode16(case: :lower)

    "#{prefix}_#{suffix}"
  end

  def migrate(opts) do
    {:ok, _pid} = start_repo()
    version = unique_version()
    :persistent_term.put({LiveSQLiteMigration, :opts}, opts)

    try do
      :ok = Ecto.Migrator.up(SQLiteRepo, version, LiveSQLiteMigration)
      version
    after
      :persistent_term.erase({LiveSQLiteMigration, :opts})
    end
  end

  def rollback(version, opts) do
    :persistent_term.put({LiveSQLiteMigration, :opts}, opts)

    try do
      Ecto.Migrator.down(SQLiteRepo, version, LiveSQLiteMigration)
    after
      :persistent_term.erase({LiveSQLiteMigration, :opts})
    end
  end

  def clear_migration(version) do
    Ecto.Adapters.SQL.query(SQLiteRepo, "DELETE FROM schema_migrations WHERE version = ?", [version])
  end

  def drop_tables(tables) do
    Enum.each(tables, fn table ->
      Ecto.Adapters.SQL.query(SQLiteRepo, "DROP TABLE IF EXISTS #{quote_name(table)}", [])
    end)
  end

  def table_exists?(table) do
    {:ok, %{rows: [[count]]}} =
      Ecto.Adapters.SQL.query(
        SQLiteRepo,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table]
      )

    count == 1
  end

  defp database_path do
    :persistent_term.get({__MODULE__, :database_path}, nil) ||
      initialize_database_path()
  end

  defp initialize_database_path do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    path =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_sqlite_#{suffix}.sqlite3"
      )

    :persistent_term.put({__MODULE__, :database_path}, path)
    path
  end

  defp quote_name(name), do: ~s("#{String.replace(to_string(name), "\"", "\"\"")}")

  defp unique_version do
    80_000_000_000_000 + System.unique_integer([:positive, :monotonic])
  end
end
