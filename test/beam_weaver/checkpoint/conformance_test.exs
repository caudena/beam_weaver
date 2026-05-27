defmodule BeamWeaver.Checkpoint.ConformanceTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Ecto
  alias BeamWeaver.Checkpoint.ETS
  alias BeamWeaver.Checkpoint.FakeSQL
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot

  for adapter <- [:ets, :ecto] do
    describe "#{adapter} checkpoint saver conformance" do
      setup do
        {:ok, saver: new_saver(unquote(adapter))}
      end

      test "puts and retrieves full checkpoint tuples", %{saver: saver} do
        config = config()

        checkpoint =
          checkpoint(
            channel_values: %{
              "str" => "hello",
              "int" => 42,
              "list" => [1, 2, 3],
              "map" => %{"nested" => true}
            },
            channel_versions: %{"str" => 1, "int" => 1, "list" => 1, "map" => 1},
            versions_seen: %{"node" => %{"str" => 1}}
          )

        metadata =
          metadata(source: "input", step: -1, custom_key: "custom", run_id: unique("run"))

        assert {:ok, stored} =
                 Checkpoint.put(
                   saver,
                   config,
                   checkpoint,
                   metadata,
                   checkpoint["channel_versions"]
                 )

        assert stored["configurable"]["thread_id"] == config["configurable"]["thread_id"]
        assert stored["configurable"]["checkpoint_ns"] == ""
        assert stored["configurable"]["checkpoint_id"] == checkpoint["id"]

        assert %{checkpoint: loaded, metadata: loaded_metadata} =
                 Checkpoint.get_tuple(saver, stored)

        assert loaded["id"] == checkpoint["id"]
        assert loaded["channel_values"] == checkpoint["channel_values"]
        assert loaded["channel_versions"] == checkpoint["channel_versions"]
        assert loaded["versions_seen"] == checkpoint["versions_seen"]
        assert loaded_metadata["source"] == "input"
        assert loaded_metadata["step"] == -1
        assert loaded_metadata["custom_key"] == "custom"
        assert loaded_metadata["run_id"] == metadata.run_id

        assert record = Checkpoint.get_record(saver, stored)
        assert record.id == checkpoint["id"]
        assert record.version == checkpoint["v"]
        assert record.source == "input"
        assert record.step == -1
        assert record.metadata.run_id == metadata.run_id
      end

      test "merges config metadata, strips null characters, and restores missing checkpoint defaults",
           %{saver: saver} do
        # Upstream reference:
        # - langgraph/libs/checkpoint-postgres/tests/test_sync.py::test_combined_metadata
        # - langgraph/libs/checkpoint-postgres/tests/test_sync.py::test_null_chars
        # - langgraph/libs/checkpoint-postgres/tests/test_sync.py::test_get_checkpoint_no_channel_values
        config =
          config()
          |> Map.put("metadata", %{
            "run_id" => unique("run"),
            "nested" => %{"nulled" => "a" <> <<0>> <> "b"}
          })

        checkpoint = %{
          "v" => 1,
          "id" => unique("checkpoint"),
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "channel_versions" => %{"foo" => 1}
        }

        assert {:ok, stored} =
                 Checkpoint.put(
                   saver,
                   config,
                   checkpoint,
                   metadata(source: "loop", step: 1, custom_key: "\0abc"),
                   %{"foo" => 1}
                 )

        assert %{checkpoint: loaded, metadata: loaded_metadata} =
                 Checkpoint.get_tuple(saver, stored)

        assert loaded["channel_values"] == %{}
        assert loaded["channel_versions"] == %{"foo" => 1}
        assert loaded["versions_seen"] == %{}
        assert loaded["pending_sends"] == []

        assert loaded_metadata["run_id"] == config["metadata"]["run_id"]
        assert loaded_metadata["custom_key"] == "abc"
        assert loaded_metadata["nested"] == %{"nulled" => "ab"}
        assert loaded_metadata["source"] == "loop"
        assert loaded_metadata["step"] == 1

        assert [%{checkpoint: listed, metadata: listed_metadata}] =
                 Checkpoint.list(saver, config, filter: %{custom_key: "abc"})

        assert listed["channel_values"] == %{}
        assert listed_metadata["custom_key"] == "abc"
      end

      test "preserves namespaces, parent configs, and thread isolation", %{saver: saver} do
        thread_id = unique("thread")
        other_thread_id = unique("thread")

        root =
          put_checkpoint!(saver, config(thread_id), %{"value" => "root"}, metadata(step: 0))

        child =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_ns: "child:1", checkpoint_id: root_id(root)),
            %{"value" => "child"},
            metadata(step: 1)
          )

        put_checkpoint!(
          saver,
          config(other_thread_id),
          %{"value" => "other"},
          metadata(step: 0)
        )

        assert %{checkpoint: %{"channel_values" => %{"value" => "root"}}} =
                 Checkpoint.get_tuple(saver, config(thread_id))

        assert %{
                 checkpoint: %{"channel_values" => %{"value" => "child"}},
                 parent_config: parent_config
               } = Checkpoint.get_tuple(saver, child)

        assert parent_config["configurable"]["thread_id"] == thread_id
        assert parent_config["configurable"]["checkpoint_ns"] == "child:1"
        assert parent_config["configurable"]["checkpoint_id"] == root_id(root)

        assert %{checkpoint: %{"channel_values" => %{"value" => "other"}}} =
                 Checkpoint.get_tuple(saver, config(other_thread_id))
      end

      test "lists newest first with namespace, metadata, before, and limit filters", %{
        saver: saver
      } do
        thread_id = unique("thread")

        stored =
          Enum.map(0..3, fn step ->
            source = if rem(step, 2) == 0, do: "input", else: "loop"

            put_checkpoint!(
              saver,
              config(thread_id),
              %{"step" => step},
              metadata(source: source, step: step, score: step)
            )
          end)

        ids = Enum.map(stored, &root_id/1)

        assert Checkpoint.list(saver, config(thread_id))
               |> Enum.map(& &1.checkpoint["id"]) == Enum.reverse(ids)

        assert Checkpoint.list(saver, config(thread_id), filter: %{source: "input"})
               |> Enum.map(& &1.metadata["step"]) == [2, 0]

        assert [%{metadata: %{"step" => 2}}] =
                 Checkpoint.list(saver, config(thread_id), filter: %{source: "input", score: 2})

        before = config(thread_id, checkpoint_id: Enum.at(ids, 2))

        assert Checkpoint.list(saver, config(thread_id), before: before, limit: 1)
               |> Enum.map(& &1.checkpoint["id"]) == [Enum.at(ids, 1)]

        put_checkpoint!(
          saver,
          config(thread_id, checkpoint_ns: "child:1"),
          %{"step" => "child"},
          metadata(step: 10)
        )

        assert [_root_only] =
                 Checkpoint.list(saver, config(thread_id, checkpoint_ns: ""), limit: 1)

        assert [_child_only] = Checkpoint.list(saver, config(thread_id, checkpoint_ns: "child:1"))
      end

      test "lists across all threads and namespaces when no config is supplied", %{saver: saver} do
        # Upstream reference:
        # langgraph/libs/checkpoint/tests/test_memory.py::TestMemorySaver.test_search
        thread_a = unique("thread")
        thread_b = unique("thread")

        put_checkpoint!(
          saver,
          config(thread_a),
          %{"value" => "a"},
          metadata(source: "input", step: 1, writes: %{"foo" => "bar"})
        )

        put_checkpoint!(
          saver,
          config(thread_b),
          %{"value" => "b-root"},
          metadata(source: "loop", step: 2, writes: %{"foo" => "baz"})
        )

        put_checkpoint!(
          saver,
          config(thread_b, checkpoint_ns: "inner"),
          %{"value" => "b-inner"},
          metadata([])
        )

        assert [%{metadata: %{"source" => "input"}}] =
                 Checkpoint.list(saver, nil, filter: %{source: "input"})

        assert [%{metadata: %{"writes" => %{"foo" => "baz"}}}] =
                 Checkpoint.list(saver, nil, filter: %{step: 2, writes: %{"foo" => "baz"}})

        assert [] = Checkpoint.list(saver, nil, filter: %{source: "missing", step: 2})
        assert length(Checkpoint.list(saver, nil, filter: %{})) == 3

        namespaces =
          saver
          |> Checkpoint.async_list(%{"configurable" => %{"thread_id" => thread_b}})
          |> Async.await()
          |> Enum.map(& &1.config["configurable"]["checkpoint_ns"])
          |> MapSet.new()

        assert namespaces == MapSet.new(["", "inner"])
      end

      test "stores pending writes by checkpoint and makes duplicate task writes idempotent", %{
        saver: saver
      } do
        thread_id = unique("thread")
        stored = put_checkpoint!(saver, config(thread_id), %{"value" => 1}, metadata(step: 0))
        task_id = unique("task")

        assert :ok =
                 Checkpoint.put_writes(
                   saver,
                   stored,
                   [{"ch1", "v1"}, {"ch2", %{"nested" => true}}],
                   task_id,
                   "subgraph:node"
                 )

        assert :ok = Checkpoint.put_writes(saver, stored, [{"ch1", "v1"}], task_id)

        assert %{
                 pending_writes: pending_writes,
                 pending_write_paths: pending_write_paths,
                 pending_write_records: pending_write_records
               } =
                 Checkpoint.get_tuple(saver, stored)

        assert Enum.sort(pending_writes) ==
                 Enum.sort([
                   {task_id, "ch1", "v1"},
                   {task_id, "ch2", %{"nested" => true}}
                 ])

        assert Enum.sort(pending_write_paths) ==
                 Enum.sort([
                   {task_id, "ch1", ""},
                   {task_id, "ch2", "subgraph:node"}
                 ])

        assert Enum.map(pending_write_records, &PendingWrite.tuple/1) == pending_writes
        assert Enum.map(pending_write_records, &PendingWrite.path_tuple/1) == pending_write_paths
        assert Enum.all?(pending_write_records, &match?(%PendingWrite{}, &1))

        assert Enum.map(pending_write_records, & &1.index) == [0, 1]
        assert Enum.all?(pending_write_records, &(&1.checkpoint_id == root_id(stored)))

        next =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(stored)),
            %{"value" => 2},
            metadata(step: 1)
          )

        assert %{pending_writes: [], pending_write_paths: [], pending_write_records: []} =
                 Checkpoint.get_tuple(saver, next)
      end

      test "async saver facade mirrors get list put writes copy delete prune operations", %{
        saver: saver
      } do
        # Upstream references:
        # - langgraph/libs/checkpoint/langgraph/checkpoint/base/__init__.py
        # - langgraph/libs/checkpoint/langgraph/checkpoint/memory/__init__.py
        thread_id = unique("async-thread")
        run_id = unique("run")

        assert {:ok, stored} =
                 Checkpoint.async_put(
                   saver,
                   config(thread_id),
                   checkpoint(channel_values: %{"value" => 1}),
                   metadata(step: 0, run_id: run_id),
                   %{"value" => 1}
                 )
                 |> Async.await()

        assert :ok =
                 Checkpoint.async_put_writes(saver, stored, [{"value", 2}], unique("task"))
                 |> Async.await()

        assert %{
                 checkpoint: %{"channel_values" => %{"value" => 1}},
                 pending_writes: [{_task_id, "value", 2}]
               } = Checkpoint.async_get_tuple(saver, stored) |> Async.await()

        assert %{"channel_values" => %{"value" => 1}} =
                 Checkpoint.async_get(saver, stored) |> Async.await()

        assert [%{metadata: %{"run_id" => ^run_id}}] =
                 Checkpoint.async_list(saver, config(thread_id), filter: %{run_id: run_id})
                 |> Async.await()

        assert :ok =
                 Checkpoint.async_copy_thread(saver, thread_id, "#{thread_id}-copy")
                 |> Async.await()

        assert %{checkpoint: %{"channel_values" => %{"value" => 1}}} =
                 Checkpoint.get_tuple(saver, config("#{thread_id}-copy"))

        assert :ok = Checkpoint.async_delete_for_runs(saver, [run_id]) |> Async.await()
        assert [] = Checkpoint.list(saver, config(thread_id), filter: %{run_id: run_id})

        assert {:ok, pruned} =
                 Checkpoint.async_put(
                   saver,
                   config(thread_id),
                   checkpoint(channel_values: %{"value" => 3}),
                   metadata(step: 1),
                   %{"value" => 3}
                 )
                 |> Async.await()

        assert :ok =
                 Checkpoint.async_prune(saver, [thread_id], strategy: :delete) |> Async.await()

        assert nil == Checkpoint.get_tuple(saver, pruned)
      end

      test "attaches parent __tasks__ pending sends to the next checkpoint only", %{
        saver: saver
      } do
        # Upstream reference:
        # - langgraph/libs/checkpoint-postgres/tests/test_sync.py::test_pending_sends_migration
        thread_id = unique("thread")

        first =
          put_checkpoint!(
            saver,
            config(thread_id),
            %{},
            metadata(step: 0)
          )

        assert :ok =
                 Checkpoint.put_writes(
                   saver,
                   first,
                   [{"__tasks__", "send-1"}, {"__tasks__", "send-2"}],
                   "task-1"
                 )

        assert :ok =
                 Checkpoint.put_writes(saver, first, [{"__tasks__", "send-3"}], "task-2")

        assert %{checkpoint: first_checkpoint} = Checkpoint.get_tuple(saver, first)
        assert first_checkpoint["channel_values"] == %{}
        assert first_checkpoint["channel_versions"] == %{}

        second =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(first)),
            %{},
            metadata(step: 1)
          )

        assert %{checkpoint: second_checkpoint} = Checkpoint.get_tuple(saver, second)
        assert second_checkpoint["channel_values"]["__tasks__"] == ["send-1", "send-2", "send-3"]
        assert Map.has_key?(second_checkpoint["channel_versions"], "__tasks__")

        [latest, earliest] = Checkpoint.list(saver, config(thread_id), limit: 2)
        assert latest.checkpoint["channel_values"]["__tasks__"] == ["send-1", "send-2", "send-3"]
        assert earliest.checkpoint["channel_values"] == %{}
      end

      test "returns delta channel history with ancestor seed and writes excluding target pending writes",
           %{saver: saver} do
        thread_id = unique("thread")

        root =
          Checkpoint.put(
            saver,
            config(thread_id),
            checkpoint(
              channel_values: %{"items" => ["seed"]},
              channel_versions: %{"items" => 1}
            ),
            metadata(step: 0),
            %{"items" => 1}
          )
          |> elem(1)

        child_checkpoint =
          checkpoint(
            channel_values: %{},
            channel_versions: %{"items" => 2},
            channel_deltas: %{"items" => ["a"]}
          )

        {:ok, child} =
          Checkpoint.put(saver, root, child_checkpoint, metadata(step: 1), %{"items" => 2})

        assert :ok = Checkpoint.put_writes(saver, child, [{"items", "b"}], unique("task"))

        {:ok, target} =
          Checkpoint.put(
            saver,
            child,
            checkpoint(channel_values: %{}, channel_versions: %{"items" => 3}),
            metadata(step: 2),
            %{"items" => 3}
          )

        assert :ok =
                 Checkpoint.put_writes(saver, target, [{"items", "target-skip"}], unique("task"))

        history = Checkpoint.get_delta_channel_history(saver, target, ["items"])

        assert history["items"].seed == ["seed"]
        assert Enum.map(history["items"].writes, & &1.value) == ["a", "b"]
      end

      test "delta channel history omits target writes and is safe under concurrent async calls",
           %{
             saver: saver
           } do
        # Upstream references:
        # langgraph/libs/checkpoint/tests/test_memory.py::TestInMemorySaverDeltaChannel
        # langgraph/libs/checkpoint/tests/test_memory.py::TestBaseFallbackGetChannelWrites
        thread_id = unique("thread")

        root =
          put_checkpoint!(
            saver,
            config(thread_id),
            %{},
            metadata(step: 0)
          )

        assert :ok = Checkpoint.put_writes(saver, root, [{"items", "pending"}], unique("task"))

        assert %{seed: missing, writes: []} =
                 Checkpoint.get_delta_channel_history(saver, root, ["items"])["items"]

        assert missing == Channel.missing()

        middle =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(root)),
            %{},
            metadata(step: 1)
          )

        assert :ok = Checkpoint.put_writes(saver, root, [{"items", "first"}], unique("task"))
        assert :ok = Checkpoint.put_writes(saver, middle, [{"items", "second"}], unique("task"))

        latest =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(middle)),
            %{},
            metadata(step: 2)
          )

        first = Checkpoint.async_get_delta_channel_history(saver, latest, ["items"])
        second = Checkpoint.async_get_delta_channel_history(saver, latest, ["items"])

        for result <- [Async.await(first), Async.await(second)] do
          assert result["items"].seed == Channel.missing()
          assert Enum.map(result["items"].writes, & &1.value) == ["pending", "first", "second"]
        end
      end

      test "delta channel history handles empty channels, independent seeds, and plain migration seeds",
           %{saver: saver} do
        # Upstream reference:
        # langgraph/libs/checkpoint-conformance/langgraph/checkpoint/conformance/spec/test_delta_channel_history.py
        thread_id = unique("thread")

        step0 = put_checkpoint!(saver, config(thread_id), %{}, metadata(step: 0))
        assert :ok = Checkpoint.put_writes(saver, step0, [{"a", 0}, {"b", 0}], unique("task"))

        {:ok, step1} =
          Checkpoint.put(
            saver,
            config(thread_id, checkpoint_id: root_id(step0)),
            checkpoint(
              channel_values: %{"a" => %DeltaSnapshot{value: "snap-a"}},
              channel_versions: %{"a" => 2}
            ),
            metadata(step: 1),
            %{"a" => 2}
          )

        assert :ok = Checkpoint.put_writes(saver, step1, [{"a", 1}, {"b", 1}], unique("task"))

        step2 =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(step1)),
            %{},
            metadata(step: 2)
          )

        assert :ok = Checkpoint.put_writes(saver, step2, [{"a", 2}, {"b", 2}], unique("task"))

        {:ok, step3} =
          Checkpoint.put(
            saver,
            config(thread_id, checkpoint_id: root_id(step2)),
            checkpoint(
              channel_values: %{"b" => %DeltaSnapshot{value: "snap-b"}},
              channel_versions: %{"b" => 4}
            ),
            metadata(step: 3),
            %{"b" => 4}
          )

        assert :ok = Checkpoint.put_writes(saver, step3, [{"a", 3}, {"b", 3}], unique("task"))

        head =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(step3)),
            %{},
            metadata(step: 4)
          )

        assert %{} == Checkpoint.get_delta_channel_history(saver, head, [])

        history = Checkpoint.get_delta_channel_history(saver, head, ["a", "b"])
        assert history["a"].seed == "snap-a"
        assert Enum.map(history["a"].writes, & &1.value) == [1, 2, 3]
        assert history["b"].seed == "snap-b"
        assert Enum.map(history["b"].writes, & &1.value) == [3]

        migration_thread = unique("thread")
        migration0 = put_checkpoint!(saver, config(migration_thread), %{}, metadata(step: 0))

        {:ok, migration1} =
          Checkpoint.put(
            saver,
            config(migration_thread, checkpoint_id: root_id(migration0)),
            checkpoint(
              channel_values: %{"items" => [10, 20, 30]},
              channel_versions: %{"items" => 2}
            ),
            metadata(step: 1),
            %{"items" => 2}
          )

        migration2 =
          put_checkpoint!(
            saver,
            config(migration_thread, checkpoint_id: root_id(migration1)),
            %{},
            metadata(step: 2)
          )

        assert :ok = Checkpoint.put_writes(saver, migration2, [{"items", 2}], unique("task"))

        migration_head =
          put_checkpoint!(
            saver,
            config(migration_thread, checkpoint_id: root_id(migration2)),
            %{},
            metadata(step: 3)
          )

        migration_history =
          Checkpoint.get_delta_channel_history(saver, migration_head, ["items"])

        assert migration_history["items"].seed == [10, 20, 30]
        assert Enum.map(migration_history["items"].writes, & &1.value) == [2]
      end

      test "matches LangGraph put_writes contract for task, channel, value, path, special channel, and namespace behavior",
           %{saver: saver} do
        thread_id = unique("thread")
        stored = put_checkpoint!(saver, config(thread_id), %{"value" => 1}, metadata(step: 0))

        task_id = unique("task")
        assert :ok = Checkpoint.put_writes(saver, stored, [{"channel1", "value1"}], task_id)

        assert %{pending_writes: [{^task_id, "channel1", "value1"}]} =
                 Checkpoint.get_tuple(saver, stored)

        multi_task = unique("task")

        assert :ok =
                 Checkpoint.put_writes(
                   saver,
                   stored,
                   [{"ch1", "v1"}, {"ch2", "v2"}, {"ch3", "v3"}],
                   multi_task,
                   "node:path"
                 )

        assert %{pending_writes: writes, pending_write_paths: paths} =
                 Checkpoint.get_tuple(saver, stored)

        assert {multi_task, "ch1", "v1"} in writes
        assert {multi_task, "ch2", "v2"} in writes
        assert {multi_task, "ch3", "v3"} in writes
        assert {multi_task, "ch1", "node:path"} in paths

        other_task = unique("task")
        assert :ok = Checkpoint.put_writes(saver, stored, [{"ch", "from-other"}], other_task)
        assert %{pending_writes: writes} = Checkpoint.get_tuple(saver, stored)
        assert {other_task, "ch", "from-other"} in writes

        special_task = unique("task")

        assert :ok =
                 Checkpoint.put_writes(
                   saver,
                   stored,
                   [{"__error__", "something went wrong"}, {"__interrupt__", %{reason: "human"}}],
                   special_task
                 )

        assert %{pending_writes: writes} = Checkpoint.get_tuple(saver, stored)
        assert {special_task, "__error__", "something went wrong"} in writes
        assert {special_task, "__interrupt__", %{reason: "human"}} in writes

        root_task = unique("task")
        child_task = unique("task")

        child =
          put_checkpoint!(saver, config(thread_id, checkpoint_ns: "child:1"), %{}, metadata([]))

        assert :ok = Checkpoint.put_writes(saver, stored, [{"ch", "root_val"}], root_task)
        assert :ok = Checkpoint.put_writes(saver, child, [{"ch", "child_val"}], child_task)

        assert %{pending_writes: root_writes} = Checkpoint.get_tuple(saver, stored)
        assert {root_task, "ch", "root_val"} in root_writes
        refute {child_task, "ch", "child_val"} in root_writes

        assert %{pending_writes: child_writes} = Checkpoint.get_tuple(saver, child)
        assert {child_task, "ch", "child_val"} in child_writes
        refute {root_task, "ch", "root_val"} in child_writes
      end

      test "copies threads, deletes threads, deletes by run id, and prunes old checkpoints", %{
        saver: saver
      } do
        source_thread = unique("thread")
        target_thread = unique("thread")
        delete_run = unique("run")
        keep_run = unique("run")

        first =
          put_checkpoint!(
            saver,
            config(source_thread),
            %{"value" => 1},
            metadata(step: 0, run_id: delete_run)
          )

        assert :ok = Checkpoint.put_writes(saver, first, [{"ch", "from-first"}], unique("task"))

        second =
          put_checkpoint!(
            saver,
            config(source_thread, checkpoint_id: root_id(first)),
            %{"value" => 2},
            metadata(step: 1, run_id: keep_run)
          )

        child =
          put_checkpoint!(
            saver,
            config(source_thread, checkpoint_ns: "child:1"),
            %{"value" => "child"},
            metadata(step: 0, run_id: delete_run)
          )

        assert :ok = Checkpoint.copy_thread(saver, source_thread, target_thread)

        assert %{checkpoint: %{"channel_values" => %{"value" => 2}}} =
                 Checkpoint.get_tuple(saver, config(target_thread))

        assert %{pending_writes: [{_task_id, "ch", "from-first"}]} =
                 Checkpoint.get_tuple(
                   saver,
                   config(target_thread, checkpoint_id: root_id(first))
                 )

        assert :ok = Checkpoint.delete_for_runs(saver, [delete_run])
        assert Checkpoint.get_tuple(saver, first) == nil
        assert Checkpoint.get_tuple(saver, child) == nil
        assert %{metadata: %{"run_id" => ^keep_run}} = Checkpoint.get_tuple(saver, second)

        older =
          put_checkpoint!(
            saver,
            config(source_thread, checkpoint_id: root_id(second)),
            %{"value" => 3},
            metadata(step: 2)
          )

        latest =
          put_checkpoint!(
            saver,
            config(source_thread, checkpoint_id: root_id(older)),
            %{"value" => 4},
            metadata(step: 3)
          )

        assert :ok = Checkpoint.prune(saver, [source_thread])
        assert Checkpoint.get_tuple(saver, older) == nil

        assert %{checkpoint: %{"channel_values" => %{"value" => 4}}} =
                 Checkpoint.get_tuple(saver, latest)

        assert :ok = Checkpoint.delete_thread(saver, source_thread)
        assert Checkpoint.list(saver, config(source_thread)) == []
      end

      test "delete_thread and delete_for_runs are no-op safe and remove writes across namespaces",
           %{saver: saver} do
        # Upstream reference:
        # langgraph/libs/checkpoint-conformance/langgraph/checkpoint/conformance/spec/test_delete_thread.py
        # langgraph/libs/checkpoint-conformance/langgraph/checkpoint/conformance/spec/test_delete_for_runs.py
        delete_thread = unique("thread")
        preserve_thread = unique("thread")
        delete_run = unique("run")
        preserve_run = unique("run")

        root =
          put_checkpoint!(
            saver,
            config(delete_thread),
            %{"value" => "delete-root"},
            metadata(step: 0, run_id: delete_run)
          )

        child =
          put_checkpoint!(
            saver,
            config(delete_thread, checkpoint_ns: "child:1"),
            %{"value" => "delete-child"},
            metadata(step: 1, run_id: delete_run)
          )

        keep =
          put_checkpoint!(
            saver,
            config(preserve_thread),
            %{"value" => "keep"},
            metadata(step: 0, run_id: preserve_run)
          )

        assert :ok = Checkpoint.put_writes(saver, root, [{"ch", "root-write"}], unique("task"))
        assert :ok = Checkpoint.put_writes(saver, child, [{"ch", "child-write"}], unique("task"))
        assert :ok = Checkpoint.put_writes(saver, keep, [{"ch", "keep-write"}], unique("task"))

        assert :ok = Checkpoint.delete_for_runs(saver, [])
        assert %{pending_writes: [_]} = Checkpoint.get_tuple(saver, root)

        assert :ok = Checkpoint.delete_for_runs(saver, [delete_run, "missing-run"])
        assert nil == Checkpoint.get_tuple(saver, root)
        assert nil == Checkpoint.get_tuple(saver, child)

        assert %{pending_writes: [{_task_id, "ch", "keep-write"}]} =
                 Checkpoint.get_tuple(saver, keep)

        assert :ok = Checkpoint.delete_thread(saver, "missing-thread")

        assert %{checkpoint: %{"channel_values" => %{"value" => "keep"}}} =
                 Checkpoint.get_tuple(saver, keep)

        assert :ok = Checkpoint.delete_thread(saver, preserve_thread)
        assert [] = Checkpoint.list(saver, config(preserve_thread))
      end

      test "copy_thread is a fork: nonexistent sources no-op and source ordering is unchanged", %{
        saver: saver
      } do
        # Upstream reference:
        # langgraph/libs/checkpoint-conformance/langgraph/checkpoint/conformance/spec/test_copy_thread.py
        source_thread = unique("thread")
        target_thread = unique("thread")

        assert :ok = Checkpoint.copy_thread(saver, "missing-source", target_thread)
        assert [] = Checkpoint.list(saver, config(target_thread))

        first =
          put_checkpoint!(
            saver,
            config(source_thread),
            %{"value" => 1},
            metadata(step: 0, tag: "first")
          )

        assert :ok = Checkpoint.put_writes(saver, first, [{"ch", "from-first"}], unique("task"))

        second =
          put_checkpoint!(
            saver,
            config(source_thread, checkpoint_id: root_id(first)),
            %{"value" => 2},
            metadata(step: 1, tag: "second")
          )

        source_before = Checkpoint.list(saver, config(source_thread))
        assert Enum.map(source_before, & &1.checkpoint["id"]) == [root_id(second), root_id(first)]

        assert :ok = Checkpoint.copy_thread(saver, source_thread, target_thread)

        target = Checkpoint.list(saver, config(target_thread))
        source_after = Checkpoint.list(saver, config(source_thread))

        assert Enum.map(target, & &1.checkpoint["id"]) ==
                 Enum.map(source_before, & &1.checkpoint["id"])

        assert Enum.map(source_after, & &1.config) == Enum.map(source_before, & &1.config)
        assert Enum.map(source_after, & &1.metadata) == Enum.map(source_before, & &1.metadata)

        assert %{pending_writes: [{_task_id, "ch", "from-first"}]} =
                 Checkpoint.get_tuple(saver, config(target_thread, checkpoint_id: root_id(first)))
      end

      test "prune keeps delta snapshot tail needed for replay while dropping older rows", %{
        saver: saver
      } do
        thread_id = unique("thread")

        old =
          put_checkpoint!(
            saver,
            config(thread_id),
            %{"other" => "old"},
            metadata(step: 0)
          )

        snapshot =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(old)),
            %{"items" => %DeltaSnapshot{value: ["seed"]}},
            metadata(step: 1)
          )

        delta =
          checkpoint(
            channel_values: %{},
            channel_versions: %{"items" => 3},
            channel_deltas: %{"items" => ["a"]}
          )

        {:ok, delta_config} =
          Checkpoint.put(saver, snapshot, delta, metadata(step: 2), %{"items" => 3})

        latest =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(delta_config)),
            %{},
            metadata(step: 3)
          )

        assert :ok = Checkpoint.prune(saver, [thread_id])

        assert Checkpoint.get_tuple(saver, old) == nil

        assert %{checkpoint: %{"channel_values" => %{"items" => %DeltaSnapshot{}}}} =
                 Checkpoint.get_tuple(saver, snapshot)

        assert %{checkpoint: %{"channel_deltas" => %{"items" => ["a"]}}} =
                 Checkpoint.get_tuple(saver, delta_config)

        assert %{metadata: %{"step" => 3}} = Checkpoint.get_tuple(saver, latest)
      end

      test "prune keep_latest is per namespace, preserves latest writes, and ignores missing threads",
           %{saver: saver} do
        # Upstream reference:
        # langgraph/libs/checkpoint-conformance/langgraph/checkpoint/conformance/spec/test_prune.py
        assert :ok = Checkpoint.prune(saver, [])
        assert :ok = Checkpoint.prune(saver, [unique("missing-thread")])

        thread_id = unique("thread")
        other_thread = unique("thread")

        root1 = put_checkpoint!(saver, config(thread_id), %{"root" => 1}, metadata(step: 0))

        root2 =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(root1)),
            %{"root" => 2},
            metadata(step: 1)
          )

        root3 =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(root2)),
            %{"root" => 3},
            metadata(step: 2)
          )

        child1 =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_ns: "child:1"),
            %{"child" => 1},
            metadata(step: 0)
          )

        child2 =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_ns: "child:1", checkpoint_id: root_id(child1)),
            %{"child" => 2},
            metadata(step: 1)
          )

        other1 =
          put_checkpoint!(saver, config(other_thread), %{"other" => 1}, metadata(step: 0))

        other2 =
          put_checkpoint!(
            saver,
            config(other_thread, checkpoint_id: root_id(other1)),
            %{"other" => 2},
            metadata(step: 1)
          )

        assert :ok = Checkpoint.put_writes(saver, root3, [{"root", "latest"}], unique("task"))
        assert :ok = Checkpoint.put_writes(saver, child2, [{"child", "latest"}], unique("task"))

        assert :ok = Checkpoint.prune(saver, [thread_id])

        assert Checkpoint.list(saver, config(thread_id))
               |> Enum.map(& &1.checkpoint["id"]) == [root_id(root3)]

        assert Checkpoint.list(saver, config(thread_id, checkpoint_ns: "child:1"))
               |> Enum.map(& &1.checkpoint["id"]) == [root_id(child2)]

        assert %{pending_writes: [{_task_id, "root", "latest"}]} =
                 Checkpoint.get_tuple(saver, root3)

        assert %{pending_writes: [{_task_id, "child", "latest"}]} =
                 Checkpoint.get_tuple(saver, child2)

        assert Checkpoint.list(saver, config(other_thread))
               |> Enum.map(& &1.checkpoint["id"]) == [root_id(other2), root_id(other1)]

        assert :ok = Checkpoint.prune(saver, [other_thread], strategy: :delete)
        assert [] = Checkpoint.list(saver, config(other_thread))
      end
    end
  end

  defp new_saver(:ets), do: ETS.new()

  defp new_saver(:ecto) do
    {:ok, repo} = FakeSQL.start_link()
    Ecto.new(repo: repo, query_module: FakeSQL)
  end

  defp put_checkpoint!(saver, config, channel_values, metadata) do
    checkpoint =
      checkpoint(
        channel_values: channel_values,
        channel_versions: Map.new(channel_values, fn {key, _value} -> {key, 1} end)
      )

    {:ok, stored} =
      Checkpoint.put(saver, config, checkpoint, metadata, checkpoint["channel_versions"])

    stored
  end

  defp config(thread_id \\ unique("thread"), opts \\ []) do
    configurable = %{
      "thread_id" => thread_id,
      "checkpoint_ns" => Keyword.get(opts, :checkpoint_ns, "")
    }

    configurable =
      case Keyword.get(opts, :checkpoint_id) do
        nil -> configurable
        checkpoint_id -> Map.put(configurable, "checkpoint_id", checkpoint_id)
      end

    %{"configurable" => configurable}
  end

  defp checkpoint(opts) do
    %{
      "v" => 1,
      "id" => Keyword.get(opts, :checkpoint_id, unique("checkpoint")),
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "channel_values" => Keyword.get(opts, :channel_values, %{}),
      "channel_versions" => Keyword.get(opts, :channel_versions, %{}),
      "versions_seen" => Keyword.get(opts, :versions_seen, %{}),
      "pending_sends" => [],
      "updated_channels" => Keyword.get(opts, :updated_channels),
      "channel_deltas" => Keyword.get(opts, :channel_deltas, %{})
    }
  end

  defp metadata(opts) do
    opts
    |> Keyword.put_new(:source, "loop")
    |> Keyword.put_new(:step, 0)
    |> Keyword.put_new(:parents, %{})
    |> Map.new()
  end

  defp root_id(config), do: config["configurable"]["checkpoint_id"]

  defp unique(prefix) do
    integer = System.unique_integer([:positive, :monotonic])
    "#{prefix}-#{String.pad_leading(Integer.to_string(integer), 20, "0")}"
  end
end
