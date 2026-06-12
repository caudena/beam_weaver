defmodule BeamWeaver.Test.PostgresRepo do
  use Ecto.Repo,
    otp_app: :beam_weaver,
    adapter: Ecto.Adapters.Postgres
end

defmodule BeamWeaver.Test.LivePostgresMigration do
  use Ecto.Migration

  def up do
    BeamWeaver.Migrations.up(:persistent_term.get({__MODULE__, :opts}))
  end

  def down do
    BeamWeaver.Migrations.down(:persistent_term.get({__MODULE__, :opts}))
  end
end

defmodule BeamWeaver.Test.LivePostgres do
  @moduledoc false

  @default_url "postgres://nate@localhost/beam_weaver"

  def url, do: BeamWeaver.Config.get([:test, :postgres_url], @default_url)

  def start_repo do
    Application.put_env(:beam_weaver, BeamWeaver.Test.PostgresRepo,
      url: url(),
      pool_size: 4,
      stacktrace: true,
      show_sensitive_data_on_connection_error: false
    )

    case Process.whereis(BeamWeaver.Test.PostgresRepo) do
      nil ->
        case BeamWeaver.Test.PostgresRepo.start_link() do
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

  def available? do
    case start_repo() do
      {:ok, _pid} ->
        case Ecto.Adapters.SQL.query(BeamWeaver.Test.PostgresRepo, "SELECT 1", []) do
          {:ok, _} -> true
          _ -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def unique_table(prefix) do
    suffix =
      :crypto.strong_rand_bytes(5)
      |> Base.encode16(case: :lower)

    "#{prefix}_#{suffix}"
  end

  def unique_schema(prefix \\ "bw_schema") do
    unique_table(prefix)
  end

  def migrate(opts) do
    version = unique_version()

    :persistent_term.put({BeamWeaver.Test.LivePostgresMigration, :opts}, opts)

    try do
      :ok =
        Ecto.Migrator.up(
          BeamWeaver.Test.PostgresRepo,
          version,
          BeamWeaver.Test.LivePostgresMigration
        )

      version
    after
      :persistent_term.erase({BeamWeaver.Test.LivePostgresMigration, :opts})
    end
  end

  def rollback(version, opts) do
    :persistent_term.put({BeamWeaver.Test.LivePostgresMigration, :opts}, opts)

    try do
      Ecto.Migrator.down(
        BeamWeaver.Test.PostgresRepo,
        version,
        BeamWeaver.Test.LivePostgresMigration
      )
    after
      :persistent_term.erase({BeamWeaver.Test.LivePostgresMigration, :opts})
    end
  end

  def clear_migration(version) do
    Ecto.Adapters.SQL.query(
      BeamWeaver.Test.PostgresRepo,
      "DELETE FROM schema_migrations WHERE version = $1",
      [version]
    )
  end

  def drop_tables(tables) do
    Enum.each(tables, fn table ->
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        "DROP TABLE IF EXISTS #{table} CASCADE",
        []
      )
    end)
  end

  def drop_schema(schema) do
    Ecto.Adapters.SQL.query(
      BeamWeaver.Test.PostgresRepo,
      "DROP SCHEMA IF EXISTS \"#{String.replace(schema, "\"", "\"\"")}\" CASCADE",
      []
    )
  end

  def table_exists?(table, schema \\ "public") do
    {:ok, %{rows: [[exists?]]}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_tables
          WHERE schemaname = $1 AND tablename = $2
        )
        """,
        [schema, table]
      )

    exists?
  end

  defp unique_version do
    90_000_000_000_000 + System.unique_integer([:positive, :monotonic])
  end
end
