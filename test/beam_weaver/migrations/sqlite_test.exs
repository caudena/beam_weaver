defmodule BeamWeaver.Migrations.SQLiteTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Test.LiveSQLite
  alias BeamWeaver.Test.SQLiteRepo

  test "migrates checkpoints and reports the current schema version" do
    {opts, checkpoints, writes} = migration_options()
    version = LiveSQLite.migrate(opts)

    on_exit(fn -> cleanup(version, checkpoints, writes) end)

    assert LiveSQLite.table_exists?(checkpoints)
    assert LiveSQLite.table_exists?(writes)
    assert BeamWeaver.Migrations.current_version(opts) == 2
    assert BeamWeaver.Migrations.migrated_version(opts) == 2
    assert :ok = BeamWeaver.Migrations.verify_migrated!(opts)
  end

  test "backfills commit order without changing legacy checkpoint ids" do
    {opts, checkpoints, writes} = migration_options()
    version1 = LiveSQLite.migrate(Keyword.put(opts, :version, 1))

    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        SQLiteRepo,
        """
        INSERT INTO "#{checkpoints}"
          (thread_id, checkpoint_ns, checkpoint_id, checkpoint, metadata, inserted_at)
        VALUES
          ('thread', '', 'z', '{}', '{}', '2026-01-01T00:00:00.000Z'),
          ('thread', '', 'a', '{}', '{}', '2026-01-01T00:00:01.000Z')
        """,
        []
      )

    version2 = LiveSQLite.migrate(opts)

    on_exit(fn ->
      LiveSQLite.drop_tables([writes, checkpoints])
      LiveSQLite.clear_migration(version1)
      LiveSQLite.clear_migration(version2)
    end)

    assert {:ok, %{rows: [["z", 1], ["a", 2]]}} =
             Ecto.Adapters.SQL.query(
               SQLiteRepo,
               "SELECT checkpoint_id, commit_order FROM \"#{checkpoints}\" ORDER BY commit_order",
               []
             )
  end

  test "migrates checkpoints down" do
    {opts, checkpoints, writes} = migration_options()
    version = LiveSQLite.migrate(opts)

    on_exit(fn -> cleanup(version, checkpoints, writes) end)

    assert :ok = LiveSQLite.rollback(version, opts)
    refute LiveSQLite.table_exists?(checkpoints)
    refute LiveSQLite.table_exists?(writes)
  end

  defp migration_options do
    checkpoints = LiveSQLite.unique_table("bw_sqlite_mig_checkpoints")
    writes = LiveSQLite.unique_table("bw_sqlite_mig_writes")

    opts = [
      repo: SQLiteRepo,
      adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]
    ]

    {opts, checkpoints, writes}
  end

  defp cleanup(version, checkpoints, writes) do
    LiveSQLite.drop_tables([writes, checkpoints])
    LiveSQLite.clear_migration(version)
  end
end
