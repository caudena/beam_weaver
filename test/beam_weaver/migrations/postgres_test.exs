defmodule BeamWeaver.Migrations.PostgresTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.PostgresRepo

  setup do
    assert LivePostgres.available?()
    :ok
  end

  test "migrates checkpoints up idempotently and records a table-comment version" do
    checkpoints = LivePostgres.unique_table("bw_mig_checkpoints")
    writes = LivePostgres.unique_table("bw_mig_writes")
    opts = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]

    version = LivePostgres.migrate(opts)
    rerun_version = LivePostgres.migrate(opts)

    on_exit(fn ->
      LivePostgres.drop_tables([writes, checkpoints])
      LivePostgres.clear_migration(version)
      LivePostgres.clear_migration(rerun_version)
    end)

    assert LivePostgres.table_exists?(checkpoints)
    assert LivePostgres.table_exists?(writes)
    assert BeamWeaver.Migrations.current_version(opts) == 1
    assert BeamWeaver.Migrations.migrated_version(Keyword.put(opts, :repo, PostgresRepo)) == 1
    assert :ok = BeamWeaver.Migrations.verify_migrated!(Keyword.put(opts, :repo, PostgresRepo))
  end

  test "migrates checkpoints down from version 1" do
    checkpoints = LivePostgres.unique_table("bw_mig_down_checkpoints")
    writes = LivePostgres.unique_table("bw_mig_down_writes")
    opts = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]

    version = LivePostgres.migrate(opts)

    on_exit(fn ->
      LivePostgres.drop_tables([writes, checkpoints])
      LivePostgres.clear_migration(version)
    end)

    assert LivePostgres.table_exists?(checkpoints)
    assert :ok = LivePostgres.rollback(version, opts)
    refute LivePostgres.table_exists?(checkpoints)
    refute LivePostgres.table_exists?(writes)
  end

  test "raises when verifying missing migrations" do
    checkpoints = LivePostgres.unique_table("bw_missing_checkpoints")
    writes = LivePostgres.unique_table("bw_missing_writes")

    opts = [
      repo: PostgresRepo,
      adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]
    ]

    assert_raise RuntimeError, ~r/BeamWeaver checkpoint migrations have not been run/, fn ->
      BeamWeaver.Migrations.verify_migrated!(opts)
    end
  end

  test "supports custom postgres prefixes and create_schema false" do
    schema = LivePostgres.unique_schema()
    checkpoints = LivePostgres.unique_table("bw_prefix_checkpoints")
    writes = LivePostgres.unique_table("bw_prefix_writes")

    missing_schema_opts = [
      prefix: schema,
      create_schema: false,
      adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]
    ]

    assert_raise Postgrex.Error, fn ->
      LivePostgres.migrate(missing_schema_opts)
    end

    opts = Keyword.put(missing_schema_opts, :create_schema, true)
    version = LivePostgres.migrate(opts)

    on_exit(fn ->
      LivePostgres.drop_schema(schema)
      LivePostgres.clear_migration(version)
    end)

    assert LivePostgres.table_exists?(checkpoints, schema)
    assert LivePostgres.table_exists?(writes, schema)
    assert BeamWeaver.Migrations.migrated_version(Keyword.put(opts, :repo, PostgresRepo)) == 1
  end

  test "supports configured pgvector table dimensions and index options" do
    table = LivePostgres.unique_table("bw_mig_vectors")

    opts = [
      adapters: [
        {:vector_store,
         table: table, dimensions: 3, distance: :l2, index: :hnsw, index_opts: [m: 32, ef_construction: 128]}
      ]
    ]

    version = LivePostgres.migrate(opts)

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version)
    end)

    assert LivePostgres.table_exists?(table)

    {:ok, %{rows: [[indexdef]]}} =
      Ecto.Adapters.SQL.query(
        PostgresRepo,
        """
        SELECT indexdef
        FROM pg_indexes
        WHERE schemaname = 'public'
        AND tablename = $1
        AND indexname = $2
        """,
        [table, "#{table}_embedding_hnsw_idx"]
      )

    assert indexdef =~ "USING hnsw"
    assert indexdef =~ "vector_l2_ops"
    assert indexdef =~ "m='32'"
    assert indexdef =~ "ef_construction='128'"
  end
end
