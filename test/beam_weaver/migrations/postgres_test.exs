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
    assert BeamWeaver.Migrations.current_version(opts) == 2
    assert BeamWeaver.Migrations.migrated_version(Keyword.put(opts, :repo, PostgresRepo)) == 2
    assert :ok = BeamWeaver.Migrations.verify_migrated!(Keyword.put(opts, :repo, PostgresRepo))
  end

  test "migrates checkpoints down from the current version" do
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

  test "backfills persisted checkpoint order when upgrading from version 1" do
    checkpoints = LivePostgres.unique_table("bw_mig_order_checkpoints")
    writes = LivePostgres.unique_table("bw_mig_order_writes")
    opts = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]

    version1 = LivePostgres.migrate(Keyword.put(opts, :version, 1))

    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        PostgresRepo,
        """
        INSERT INTO #{checkpoints}
          (thread_id, checkpoint_ns, checkpoint_id, checkpoint, metadata, inserted_at)
        VALUES
          ('thread', '', 'z', '{}', '{}', '2026-01-01T00:00:00Z'),
          ('thread', '', 'a', '{}', '{}', '2026-01-01T00:00:01Z')
        """,
        []
      )

    version2 = LivePostgres.migrate(opts)

    on_exit(fn ->
      LivePostgres.drop_tables([writes, checkpoints])
      LivePostgres.clear_migration(version1)
      LivePostgres.clear_migration(version2)
    end)

    assert {:ok, %{rows: [["z", 1], ["a", 2]]}} =
             Ecto.Adapters.SQL.query(
               PostgresRepo,
               "SELECT checkpoint_id, commit_order FROM #{checkpoints} ORDER BY commit_order",
               []
             )
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
    assert BeamWeaver.Migrations.migrated_version(Keyword.put(opts, :repo, PostgresRepo)) == 2
  end

  test "memory schema version 2 keeps each record's lifetime and backfills existing records" do
    table = LivePostgres.unique_table("bw_mig_memory_ttl")
    opts = [adapters: [{:memory, table: table}]]

    version1 = LivePostgres.migrate(Keyword.put(opts, :version, 1))

    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        PostgresRepo,
        """
        INSERT INTO #{table} (namespace, key, value, updated_at, expires_at)
        VALUES ('{notes}', 'old', '{}', now(), now() + interval '30 minutes')
        """,
        []
      )

    assert_raise RuntimeError, ~r/memory migrations are outdated/, fn ->
      BeamWeaver.Migrations.verify_migrated!(Keyword.put(opts, :repo, PostgresRepo))
    end

    version2 = LivePostgres.migrate(opts)

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version1)
      LivePostgres.clear_migration(version2)
    end)

    assert :ok = BeamWeaver.Migrations.verify_migrated!(Keyword.put(opts, :repo, PostgresRepo))

    store = BeamWeaver.Memory.Ecto.new(repo: PostgresRepo, table: table, refresh_ttl: true)
    assert {:ok, %{ttl: ttl}} = BeamWeaver.Memory.get(store, ["notes"], "old")
    assert_in_delta ttl, 30, 0.01
  end

  test "memory schema version 2 gives the records the version 1 store refreshed at most default_ttl:" do
    table = LivePostgres.unique_table("bw_mig_memory_refreshed")
    opts = [adapters: [{:memory, table: table, default_ttl: 60 * 24}]]

    version1 = LivePostgres.migrate(Keyword.put(opts, :version, 1))

    # "refreshed" was written 29 days ago for a day, and the version 1 store
    # refreshed it a moment ago: its expiry moved, its write time stayed.
    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        PostgresRepo,
        """
        INSERT INTO #{table} (namespace, key, value, updated_at, expires_at)
        VALUES ('{notes}', 'refreshed', '{}', now() - interval '29 days', now() + interval '1 day'),
               ('{notes}', 'short', '{}', now(), now() + interval '30 minutes'),
               ('{notes}', 'kept', '{}', now(), NULL)
        """,
        []
      )

    version2 = LivePostgres.migrate(opts)

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version1)
      LivePostgres.clear_migration(version2)
    end)

    store = BeamWeaver.Memory.Ecto.new(repo: PostgresRepo, table: table)
    assert {:ok, %{ttl: refreshed}} = BeamWeaver.Memory.get(store, ["notes"], "refreshed")
    assert_in_delta refreshed, 60 * 24, 0.01
    assert {:ok, %{ttl: short}} = BeamWeaver.Memory.get(store, ["notes"], "short")
    assert_in_delta short, 30, 0.01
    assert {:ok, %{ttl: nil, expires_at: nil}} = BeamWeaver.Memory.get(store, ["notes"], "kept")

    assert_raise ArgumentError, ~r/default_ttl/, fn ->
      BeamWeaver.Migrations.current_version(adapters: [{:memory, default_ttl: 0}])
    end
  end

  test "a vector store without an index takes embeddings of more than 2,000 dimensions" do
    table = LivePostgres.unique_table("bw_mig_large_vectors")
    version = LivePostgres.migrate(adapters: [{:vector_store, table: table, dimensions: 3_072, index: false}])

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version)
    end)

    {:ok, %{rows: indexes}} =
      Ecto.Adapters.SQL.query(
        PostgresRepo,
        "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename = $1 ORDER BY indexname",
        [table]
      )

    assert indexes == [["#{table}_namespace_idx"], ["#{table}_pkey"]]

    store =
      BeamWeaver.VectorStore.EctoPostgres.new(
        repo: PostgresRepo,
        table: table,
        embedding: %BeamWeaver.Models.FakeEmbeddingModel{dimensions: 3_072},
        dimensions: 3_072
      )

    docs = [BeamWeaver.Core.Document.new!("alpha"), BeamWeaver.Core.Document.new!("beta")]
    assert {:ok, [_id1, _id2]} = BeamWeaver.VectorStore.add_documents(store, docs)
    assert {:ok, [_first, _second]} = BeamWeaver.VectorStore.similarity_search(store, "alpha", k: 2)
  end

  test "keeps the tables of every adapter in the schema that prefix: names" do
    schema = LivePostgres.unique_schema()
    checkpoints = LivePostgres.unique_table("bw_prefix_checkpoints")
    writes = LivePostgres.unique_table("bw_prefix_writes")

    opts = [
      prefix: schema,
      adapters: [
        {:checkpoint, checkpoints_table: checkpoints, writes_table: writes},
        {:memory, table: "memory"},
        {:cache, table: "cache"},
        {:vector_store, table: "vectors", dimensions: 3},
        {:record_manager, table: "records"}
      ]
    ]

    version = LivePostgres.migrate(opts)

    on_exit(fn ->
      LivePostgres.drop_schema(schema)
      LivePostgres.clear_migration(version)
    end)

    assert :ok = BeamWeaver.Migrations.verify_migrated!(Keyword.put(opts, :repo, PostgresRepo))

    saver =
      BeamWeaver.Checkpoint.Ecto.new(
        repo: PostgresRepo,
        prefix: schema,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    config = %{"configurable" => %{"thread_id" => "prefixed", "checkpoint_ns" => ""}}
    checkpoint = %{"v" => 1, "id" => "cp-1", "channel_values" => %{"answer" => 42}, "channel_versions" => %{}}

    assert {:ok, stored} = BeamWeaver.Checkpoint.put(saver, config, checkpoint, %{"run_id" => "run-1"}, %{})
    assert :ok = BeamWeaver.Checkpoint.put_writes(saver, stored, [{"answer", 43}], "task-1")
    assert %{checkpoint: %{"id" => "cp-1"}, pending_writes: [_write]} = BeamWeaver.Checkpoint.get_tuple(saver, stored)
    assert [%{checkpoint: %{"id" => "cp-1"}}] = BeamWeaver.Checkpoint.list(saver, config, filter: %{run_id: "run-1"})
    assert :ok = BeamWeaver.Checkpoint.copy_thread(saver, "prefixed", "copied")
    assert :ok = BeamWeaver.Checkpoint.delete_for_runs(saver, ["run-1"])
    assert [] = BeamWeaver.Checkpoint.list(saver, nil)

    memory = BeamWeaver.Memory.Ecto.new(repo: PostgresRepo, prefix: schema, table: "memory")
    assert {:ok, _item} = BeamWeaver.Memory.put(memory, ["notes"], "a", %{"v" => 1})
    assert [%{key: "a"}] = BeamWeaver.Memory.search(memory, ["notes"])
    assert {:ok, 1} = BeamWeaver.Memory.prune(memory, max_entries: 0)

    cache = BeamWeaver.Cache.Ecto.new(repo: PostgresRepo, prefix: schema, table: "cache")
    assert :ok = BeamWeaver.Cache.put(cache, :answers, "q", 42)
    assert {:hit, 42, %{}} = BeamWeaver.Cache.lookup(cache, :answers, "q")

    vectors =
      BeamWeaver.VectorStore.EctoPostgres.new(
        repo: PostgresRepo,
        prefix: schema,
        table: "vectors",
        embedding: %BeamWeaver.Models.FakeEmbeddingModel{dimensions: 3},
        dimensions: 3
      )

    assert {:ok, [_id]} = BeamWeaver.VectorStore.add_documents(vectors, [BeamWeaver.Core.Document.new!("alpha")])
    assert {:ok, [%{content: "alpha"}]} = BeamWeaver.VectorStore.similarity_search(vectors, "alpha", k: 1)

    records = BeamWeaver.Indexing.RecordManager.EctoPostgres.new(repo: PostgresRepo, prefix: schema, table: "records")
    record = %BeamWeaver.Indexing.Record{id: "doc-1", source_id: "source-a", hash: "hash-a"}
    assert :ok = BeamWeaver.Indexing.RecordManager.put(records, record)
    assert {:ok, %{id: "doc-1"}} = BeamWeaver.Indexing.RecordManager.get(records, "doc-1")

    {:ok, %{rows: counts}} =
      Ecto.Adapters.SQL.query(
        PostgresRepo,
        """
        SELECT (SELECT count(*) FROM "#{schema}".cache), (SELECT count(*) FROM "#{schema}".vectors),
               (SELECT count(*) FROM "#{schema}".records)
        """,
        []
      )

    assert counts == [[1, 1, 1]]
    refute LivePostgres.table_exists?(checkpoints)
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
