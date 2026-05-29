defmodule BeamWeaver.Adapters.LivePostgresTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias BeamWeaver.Cache
  alias BeamWeaver.Cache.Ecto, as: EctoCache
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Ecto, as: EctoCheckpoint
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Indexing.Record
  alias BeamWeaver.Indexing.RecordManager
  alias BeamWeaver.Indexing.RecordManager.EctoPostgres, as: EctoRecordManager
  alias BeamWeaver.Memory
  alias BeamWeaver.Memory.Ecto, as: EctoMemory
  alias BeamWeaver.Memory.GetOp
  alias BeamWeaver.Memory.ListNamespacesOp
  alias BeamWeaver.Memory.PutOp
  alias BeamWeaver.Memory.SearchOp
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.Tracing.Exporters.LangSmith.QueueStore.Ecto, as: LangSmithQueueEcto
  alias BeamWeaver.Tracing.Run
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.EctoPostgres, as: EctoVectorStore

  setup do
    assert BeamWeaver.Test.LivePostgres.available?()
    :ok
  end

  test "checkpoint commits checkpoint and pending writes transactionally" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    config = %{"configurable" => %{"thread_id" => "thread-live"}}
    checkpoint = %{"id" => "cp-ok", "channel_values" => %{"answer" => 1}}

    assert {:ok, next_config} =
             Checkpoint.put_checkpoint_with_writes(
               saver,
               config,
               checkpoint,
               %{source: "loop", run_id: "run-live"},
               %{"answer" => 1},
               [{"answer", 1}],
               task_id: "task-ok",
               task_path: "node:ok"
             )

    assert %{pending_writes: [{"task-ok", "answer", 1}]} =
             Checkpoint.get_tuple(saver, next_config)

    bad_checkpoint = %{"id" => "cp-bad", "channel_values" => %{"answer" => 2}}

    assert {:error, _reason} =
             Checkpoint.put_checkpoint_with_writes(
               saver,
               config,
               bad_checkpoint,
               %{source: "loop"},
               %{},
               [{"bad", self()}],
               task_id: "task-bad"
             )

    refute Checkpoint.get_tuple(
             saver,
             %{"configurable" => %{"thread_id" => "thread-live", "checkpoint_id" => "cp-bad"}}
           )
  end

  test "checkpoint postgres saver matches metadata and pending-send behavior live" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    config = %{
      "configurable" => %{"thread_id" => "thread-live-checkpoint"},
      "metadata" => %{"run_id" => "run-from-config"}
    }

    {:ok, first} =
      Checkpoint.put(
        saver,
        config,
        %{"id" => "cp-parent", "channel_versions" => %{}},
        %{source: "loop", step: 1, custom_key: "\0abc"},
        %{}
      )

    assert %{checkpoint: parent_checkpoint, metadata: parent_metadata} =
             Checkpoint.get_tuple(saver, first)

    assert parent_checkpoint["channel_values"] == %{}
    assert parent_metadata["run_id"] == "run-from-config"
    assert parent_metadata["custom_key"] == "abc"

    assert :ok =
             Checkpoint.put_writes(
               saver,
               first,
               [{"__tasks__", "send-1"}, {"__tasks__", "send-2"}],
               "task-1"
             )

    {:ok, second} =
      Checkpoint.put(
        saver,
        first,
        %{"id" => "cp-child", "channel_versions" => %{}},
        %{source: "loop", step: 2},
        %{}
      )

    assert %{checkpoint: child_checkpoint} = Checkpoint.get_tuple(saver, second)
    assert child_checkpoint["channel_values"]["__tasks__"] == ["send-1", "send-2"]
    assert Map.has_key?(child_checkpoint["channel_versions"], "__tasks__")
  end

  test "checkpoint stores BeamWeaver structs as tagged jsonb and restores them live" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_structs")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_structs")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    config = %{"configurable" => %{"thread_id" => "thread-live-structs"}}

    user_message =
      Message.user("hello",
        metadata: %{source: :live_postgres},
        artifacts: [ContentBlock.text("artifact")]
      )

    assert {:ok, next_config} =
             Checkpoint.put(
               saver,
               config,
               %{
                 "id" => "cp-structs",
                 "channel_values" => %{
                   "messages" => [user_message],
                   "snapshot" => %DeltaSnapshot{value: ["seed"]},
                   "block" => ContentBlock.text("inline block")
                 }
               },
               %{source: "loop", run_id: "run-structs"},
               %{}
             )

    assert :ok =
             Checkpoint.put_writes(
               saver,
               next_config,
               [{"messages", Message.assistant("pending")}],
               "task-structs"
             )

    {:ok, %{rows: [[stored_message, stored_snapshot, stored_write]]}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        """
        SELECT
          checkpoint->'channel_values'->'messages'->0,
          checkpoint->'channel_values'->'snapshot',
          value
        FROM #{checkpoints}
        JOIN #{writes}
          USING (thread_id, checkpoint_ns, checkpoint_id)
        WHERE #{checkpoints}.checkpoint_id = $1
        """,
        ["cp-structs"]
      )

    assert stored_message["__beam_weaver_type__"] == "beam_weaver.core.message"

    assert stored_message["artifacts"] == [
             %{
               "__beam_weaver_type__" => "beam_weaver.core.content_block.text",
               "metadata" => %{},
               "text" => "artifact",
               "type" => %{"__beam_weaver_type__" => "atom", "value" => "text"}
             }
           ]

    assert stored_snapshot["__beam_weaver_type__"] == "beam_weaver.graph.channels.delta_snapshot"
    assert stored_write["__beam_weaver_type__"] == "beam_weaver.core.message"

    assert %{
             checkpoint: %{
               "channel_values" => %{
                 "messages" => [%Message{role: :user, metadata: %{"source" => :live_postgres}}],
                 "snapshot" => %DeltaSnapshot{value: ["seed"]},
                 "block" => %ContentBlock.Text{text: "inline block"}
               }
             },
             metadata: %{"run_id" => "run-structs"},
             pending_writes: [{"task-structs", "messages", %Message{role: :assistant, content: "pending"}}]
           } = Checkpoint.get_tuple(saver, next_config)
  end

  test "checkpoint shallow postgres saver keeps only the latest checkpoint live" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_shallow")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_shallow")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes,
        shallow?: true
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    config = %{"configurable" => %{"thread_id" => "thread-live-shallow"}}

    {:ok, first_config} =
      Checkpoint.put(
        saver,
        config,
        %{"id" => "cp-shallow-1", "channel_values" => %{"step" => 1}},
        %{source: "loop"},
        %{"step" => 1}
      )

    assert :ok = Checkpoint.put_writes(saver, first_config, [{"step", 1}], "task-live")

    {:ok, second_config} =
      Checkpoint.put(
        saver,
        first_config,
        %{"id" => "cp-shallow-2", "channel_values" => %{"step" => 2}},
        %{source: "loop"},
        %{"step" => 2}
      )

    assert [%{checkpoint: %{"id" => "cp-shallow-2"}, pending_writes: []}] =
             Checkpoint.list(saver, config)

    refute Checkpoint.get_tuple(saver, first_config)

    assert %{checkpoint: %{"id" => "cp-shallow-2"}, parent_config: nil} =
             Checkpoint.get_tuple(saver, second_config)
  end

  test "cache stores safe serialized values, TTLs, sweep, and namespace clear" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_cache")

    cache =
      EctoCache.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table
      )

    version = BeamWeaver.Test.LivePostgres.migrate(adapters: [{:cache, table: table}])

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    assert :ok =
             Cache.put(cache, [:tenant, "a"], %{id: 1}, %{"answer" => 42}, metadata: %{model: "fake"})

    assert {:hit, %{"answer" => 42}, %{"model" => "fake"}} =
             Cache.lookup(cache, [:tenant, "a"], %{id: 1})

    {:ok, %{rows: [[blob]]}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        "SELECT value FROM #{table} LIMIT 1",
        []
      )

    refute match?(<<131, _::binary>>, blob)

    assert :ok = Cache.put(cache, :ttl, "key", "gone", ttl: 1)
    Process.sleep(5)
    assert {:ok, _count} = EctoCache.sweep_expired(cache)
    assert :miss = Cache.lookup(cache, :ttl, "key")

    assert :ok = Cache.clear(cache, [:tenant, "a"])
    assert :miss = Cache.lookup(cache, [:tenant, "a"], %{id: 1})
  end

  test "cache rejects corrupt values and legacy ETF payloads through the public codec path" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_cache_codec")

    cache =
      EctoCache.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table
      )

    version = BeamWeaver.Test.LivePostgres.migrate(adapters: [{:cache, table: table}])

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    namespace = [:tenant, "legacy"]
    corrupt_key = "corrupt"
    legacy_key = "legacy-etf"

    assert {:ok, _result} =
             Ecto.Adapters.SQL.query(
               BeamWeaver.Test.PostgresRepo,
               """
               INSERT INTO #{table} (namespace, key, value, metadata, expires_at)
               VALUES ($1, $2, $3, $4, NULL), ($5, $6, $7, $8, NULL)
               """,
               [
                 Cache.stable_key(namespace),
                 Cache.stable_key(corrupt_key),
                 "not-json",
                 %{},
                 Cache.stable_key(namespace),
                 Cache.stable_key(legacy_key),
                 :erlang.term_to_binary(%{"legacy" => true}),
                 %{}
               ]
             )

    assert {:error, %BeamWeaver.Core.Error{type: :serialization_error}} =
             Cache.lookup(cache, namespace, corrupt_key)

    assert {:error, %BeamWeaver.Core.Error{type: :serialization_error}} =
             Cache.lookup(cache, namespace, legacy_key)

    refute Map.has_key?(cache.serialization, :trusted_local_etf?)
  end

  test "memory store batch order, namespace filters, nested filters, and ttl refresh work live" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_memory")

    store =
      EctoMemory.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table,
        refresh_on_read?: true,
        default_ttl: 0.01
      )

    version = BeamWeaver.Test.LivePostgres.migrate(adapters: [{:memory, table: table}])

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    ops = [
      %PutOp{
        namespace: ["tenant", "docs"],
        key: "a",
        value: %{"nested" => %{"rank" => 2}},
        ttl: 0.01
      },
      %PutOp{namespace: ["tenant", "docs"], key: "b", value: %{"nested" => %{"rank" => 4}}},
      %SearchOp{namespace: ["tenant"], filter: %{"nested.rank" => %{"$gte" => 3}}, limit: 10},
      %ListNamespacesOp{match_conditions: [], max_depth: 2, limit: 10},
      %GetOp{namespace: ["tenant", "docs"], key: "a"}
    ]

    assert [nil, nil, [%{key: "b"}], namespaces, %{key: "a", expires_at: refreshed}] =
             Memory.batch(store, ops)

    assert ["tenant", "docs"] in namespaces
    assert refreshed

    assert {:ok, _count} = EctoMemory.sweep_expired(store)
  end

  test "pgvector adapter setup, search, score, MMR, and delete work live" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_vectors")

    store =
      EctoVectorStore.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table,
        namespace: "tenant-a",
        embedding: %FakeEmbeddingModel{dimensions: 3},
        dimensions: 3,
        index: :hnsw
      )

    version =
      BeamWeaver.Test.LivePostgres.migrate(
        adapters: [
          {:vector_store, table: table, dimensions: 3, index: :hnsw}
        ]
      )

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    docs = [
      Document.new!("alpha document", metadata: %{group: "a", nested: %{rank: 1}}),
      Document.new!("beta document", metadata: %{group: "b", nested: %{rank: 3}})
    ]

    assert {:ok, [id1, id2]} = VectorStore.add_documents(store, docs)

    assert {:ok, [{%Document{} = doc, score} | _]} =
             VectorStore.similarity_search_with_score(store, "beta", k: 2)

    assert is_binary(doc.content)
    assert is_number(score)

    assert {:ok, [%Document{content: "beta document"}]} =
             VectorStore.similarity_search(store, "beta",
               k: 2,
               filter: %{"nested.rank" => %{gte: 2}}
             )

    assert {:ok, [%Document{} | _]} =
             VectorStore.max_marginal_relevance_search(store, "alpha", k: 1)

    assert :ok = VectorStore.delete(store, [id1, id2])
    assert {:ok, []} = VectorStore.similarity_search(store, "alpha", k: 2)
  end

  test "record manager stores and filters indexing records live" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_records")

    manager =
      EctoRecordManager.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table,
        namespace: "tenant-a"
      )

    version = BeamWeaver.Test.LivePostgres.migrate(adapters: [{:record_manager, table: table}])

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    assert :ok =
             RecordManager.put(manager, %Record{
               id: "doc-1",
               source_id: "source-a",
               hash: "hash-a",
               metadata: %{kind: "live"}
             })

    assert {:ok, %Record{id: "doc-1", metadata: %{"kind" => "live"}}} =
             RecordManager.get(manager, "doc-1")

    assert {:ok, [%Record{id: "doc-1"}]} =
             RecordManager.list(manager, source_ids: ["source-a"])

    assert :ok = RecordManager.delete(manager, ["doc-1"])
    assert {:ok, nil} = RecordManager.get(manager, "doc-1")
  end

  test "LangSmith queue store persists safe serialized queue items live" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_langsmith_queue")

    store =
      LangSmithQueueEcto.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table
      )

    version = BeamWeaver.Test.LivePostgres.migrate(adapters: [{:langsmith_queue, table: table}])

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    item = %{
      id: "queue-item-1",
      event: :ok,
      run:
        Run.new("queued",
          id: "run-live-queue",
          trace_id: "trace-live-queue",
          kind: :graph,
          started_at: ~U[2026-05-22 00:00:00Z],
          metadata: %{nested: %{rank: 1}}
        ),
      opts: [],
      attempts: 0,
      retry_at: 0,
      enqueued_at: 1
    }

    assert :ok = LangSmithQueueEcto.put(store, item)

    assert [%{id: "queue-item-1", run: %Run{id: "run-live-queue"}}] =
             LangSmithQueueEcto.list(store, [])

    {:ok, %{rows: [[blob]]}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        "SELECT item FROM #{table} LIMIT 1",
        []
      )

    refute match?(<<131, _::binary>>, blob)

    assert :ok = LangSmithQueueEcto.delete(store, "queue-item-1")
    assert [] = LangSmithQueueEcto.list(store, [])
  end
end
