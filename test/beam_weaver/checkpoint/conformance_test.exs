defmodule BeamWeaver.Checkpoint.ConformanceTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Ecto
  alias BeamWeaver.Checkpoint.ETS
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Graph.Interrupt
  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.LiveSQLite
  alias BeamWeaver.Test.PostgresRepo
  alias BeamWeaver.Test.SQLiteRepo

  # The `_encrypted` savers store every checkpoint, write and metadata map
  # encrypted, so SQL can't read their metadata.
  for adapter <- [:ets, :postgres, :sqlite, :postgres_encrypted, :sqlite_encrypted] do
    describe "#{adapter} checkpoint saver conformance" do
      if adapter in [:postgres, :postgres_encrypted] do
        @describetag :postgres
      end

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

      test "gives back maps with the keys they were put with, at any depth", %{saver: saver} do
        line = %{sku: "S-1", qty: 2}
        order = %{:id => "A-1001", :status => :open, :lines => [line], "gift_note" => "Happy birthday"}
        channel_values = %{order: order, totals: %{1 => 40, 2 => 15}, paid: %{true => ["A-1001"], false => []}}
        metadata = metadata(source: "loop", step: 1, step_update: %{load: %{order: order}})

        assert {:ok, stored} =
                 Checkpoint.put(saver, config(), checkpoint(channel_values: channel_values), metadata, %{})

        interrupt = %Interrupt{id: "interrupt-1", value: %{question: "Refund this line?", line: line}}
        writes = [{"order", %{order: order}}, {"__interrupt__", [interrupt]}]
        assert :ok = Checkpoint.put_writes(saver, stored, writes, "task-1")

        assert %{checkpoint: loaded, metadata: loaded_metadata, pending_writes: pending_writes} =
                 Checkpoint.get_tuple(saver, stored)

        assert loaded["channel_values"] == channel_values
        assert loaded_metadata["step_update"] == %{load: %{order: order}}
        assert pending_writes == [{"task-1", "order", %{order: order}}, {"task-1", "__interrupt__", [interrupt]}]
      end

      # `Checkpoint.ETS` compares a filter's top-level values for equality;
      # the Ecto saver matches the leaves of nested maps.
      if adapter != :ets do
        test "matches nested metadata filters whether their keys are atoms or strings", %{saver: saver} do
          config = config()
          put_checkpoint!(saver, config, %{}, metadata(step: 1, step_update: %{"review" => %{"verdict" => "revise"}}))
          put_checkpoint!(saver, config, %{}, metadata(step: 2, step_update: %{review: %{verdict: "accept", score: 4}}))

          assert [%{metadata: %{"step" => 1}}] =
                   Checkpoint.list(saver, config, filter: %{step_update: %{review: %{verdict: "revise"}}})

          assert [%{metadata: %{"step" => 2}}] =
                   Checkpoint.list(saver, config, filter: %{step_update: %{"review" => %{"verdict" => "accept"}}})

          assert [%{metadata: %{"step" => 2}}] =
                   Checkpoint.list(saver, config, filter: %{step_update: %{review: %{verdict: "accept"}}})
        end

        # `Checkpoint.ETS` numbers checkpoints with a counter that lives as long
        # as its table; the Ecto saver's ids must stay unique across restarts.
        test "gives a checkpoint without an id a UUIDv7", %{saver: saver} do
          config = config()
          new = Map.delete(checkpoint([]), "id")

          assert {:ok, first} = Checkpoint.put(saver, config, new, metadata(step: 1), %{})
          assert {:ok, second} = Checkpoint.put(saver, first, new, metadata(step: 2), %{})

          ids = Enum.map([first, second], & &1["configurable"]["checkpoint_id"])
          assert Enum.all?(ids, &(&1 =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/))
          assert Enum.uniq(ids) == ids
          assert [%{metadata: %{"step" => 2}}, %{metadata: %{"step" => 1}}] = Checkpoint.list(saver, config)
        end
      end

      test "merges config metadata, strips null characters, and restores missing checkpoint defaults",
           %{saver: saver} do
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
          |> Checkpoint.list(%{"configurable" => %{"thread_id" => thread_b}})
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

      test "saver facade covers get list put writes copy delete prune operations", %{saver: saver} do
        thread_id = unique("async-thread")
        run_id = unique("run")

        assert {:ok, stored} =
                 Checkpoint.put(
                   saver,
                   config(thread_id),
                   checkpoint(channel_values: %{"value" => 1}),
                   metadata(step: 0, run_id: run_id),
                   %{"value" => 1}
                 )

        assert :ok = Checkpoint.put_writes(saver, stored, [{"value", 2}], unique("task"))

        assert %{
                 checkpoint: %{"channel_values" => %{"value" => 1}},
                 pending_writes: [{_task_id, "value", 2}]
               } = Checkpoint.get_tuple(saver, stored)

        assert %{"channel_values" => %{"value" => 1}} = Checkpoint.get(saver, stored)

        assert [%{metadata: %{"run_id" => ^run_id}}] =
                 Checkpoint.list(saver, config(thread_id), filter: %{run_id: run_id})

        assert :ok = Checkpoint.copy_thread(saver, thread_id, "#{thread_id}-copy")

        assert %{checkpoint: %{"channel_values" => %{"value" => 1}}} =
                 Checkpoint.get_tuple(saver, config("#{thread_id}-copy"))

        assert :ok = Checkpoint.delete_for_runs(saver, [run_id])
        assert [] = Checkpoint.list(saver, config(thread_id), filter: %{run_id: run_id})

        assert {:ok, pruned} =
                 Checkpoint.put(
                   saver,
                   config(thread_id),
                   checkpoint(channel_values: %{"value" => 3}),
                   metadata(step: 1),
                   %{"value" => 3}
                 )

        assert :ok = Checkpoint.prune(saver, [thread_id], strategy: :delete)

        assert nil == Checkpoint.get_tuple(saver, pruned)
      end

      test "attaches parent __tasks__ pending sends to the next checkpoint only", %{
        saver: saver
      } do
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

      test "delta channel history omits target writes and returns ancestor writes without a seed",
           %{saver: saver} do
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

        history = Checkpoint.get_delta_channel_history(saver, latest, ["items"])

        assert history["items"].seed == Channel.missing()
        assert Enum.map(history["items"].writes, & &1.value) == ["pending", "first", "second"]
      end

      test "delta channel history handles empty channels, independent seeds, and plain migration seeds",
           %{saver: saver} do
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

      test "matches put_writes behavior for task, channel, value, path, special channel, and namespace behavior",
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
                   [{"__error__", "something went wrong"}, {"__interrupt__", %{"reason" => "human"}}],
                   special_task
                 )

        assert %{pending_writes: writes} = Checkpoint.get_tuple(saver, stored)
        assert {special_task, "__error__", "something went wrong"} in writes
        assert {special_task, "__interrupt__", %{"reason" => "human"}} in writes

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

      test "delta channel history starts at the nearest of several snapshots", %{saver: saver} do
        thread_id = unique("thread")

        head =
          Enum.reduce(0..5, config(thread_id), fn step, parent ->
            values = if step in [0, 3], do: %{"ch" => %DeltaSnapshot{value: step}}, else: %{}
            stored = put_checkpoint!(saver, parent, values, metadata(step: step))
            if step not in [0, 3], do: :ok = Checkpoint.put_writes(saver, stored, [{"ch", step}], unique("task"))
            stored
          end)

        assert %{"ch" => %{seed: 3, writes: [%PendingWrite{value: 4}]}} =
                 Checkpoint.get_delta_channel_history(saver, head, ["ch"])
      end

      test "delta channel history replays the writes saved on a plain value seed, and reads the latest checkpoint without an id",
           %{saver: saver} do
        thread_id = unique("thread")
        writes = %{0 => "older", 1 => "on-seed", 2 => "after-seed", 3 => "on-head"}

        head =
          Enum.reduce(0..3, config(thread_id), fn step, parent ->
            values = Map.get(%{0 => %{"ch" => [10]}, 1 => %{"ch" => [10, 20]}}, step, %{})
            stored = put_checkpoint!(saver, parent, values, metadata(step: step))
            :ok = Checkpoint.put_writes(saver, stored, [{"ch", writes[step]}], unique("task"))
            stored
          end)

        history = Checkpoint.get_delta_channel_history(saver, head, ["ch"])
        assert history["ch"].seed == [10, 20]
        assert Enum.map(history["ch"].writes, & &1.value) == ["on-seed", "after-seed"]
        assert Checkpoint.get_delta_channel_history(saver, config(thread_id), ["ch"]) == history
      end

      test "a checkpoint put again under its descendant keeps its parent", %{saver: saver} do
        thread_id = unique("thread")
        first = put_checkpoint!(saver, config(thread_id), %{}, metadata(step: 0))
        second = put_checkpoint!(saver, first, %{}, metadata(step: 1))

        assert {:ok, _config} =
                 Checkpoint.put(saver, second, checkpoint(checkpoint_id: root_id(first)), metadata(step: 0), %{})

        assert %{parent_config: nil} = Checkpoint.get_tuple(saver, first)
        assert %{"ch" => %{writes: []}} = Checkpoint.get_delta_channel_history(saver, second, ["ch"])
      end

      test "prune rejects an unknown strategy and keeps the thread", %{saver: saver} do
        thread_id = unique("thread")
        first = put_checkpoint!(saver, config(thread_id), %{"value" => 1}, metadata(step: 0))
        put_checkpoint!(saver, first, %{"value" => 2}, metadata(step: 1))

        assert {:error, %Error{type: :invalid_prune_strategy}} =
                 Checkpoint.prune(saver, [thread_id], strategy: :keep_all)

        assert length(Checkpoint.list(saver, config(thread_id))) == 2
      end

      test "prune keeps the delta history of the latest checkpoint's branch, not the newest snapshot's",
           %{saver: saver} do
        # root -> step -> snapshot -> older_branch
        #         step -> forked -> latest
        thread_id = unique("thread")
        root = put_step!(saver, config(thread_id), %{}, %{"items" => ["a"]})
        step = put_step!(saver, root, %{}, %{"items" => ["b"]})
        snapshot = put_step!(saver, step, %{"items" => %DeltaSnapshot{value: ["a", "b", "s"]}}, %{})
        older_branch = put_step!(saver, snapshot, %{}, %{"items" => ["c"]})
        forked = put_step!(saver, step, %{}, %{"items" => ["d"]})
        latest = put_step!(saver, forked, %{}, %{"items" => ["e"]})
        history = Checkpoint.get_delta_channel_history(saver, latest, ["items"])

        assert :ok = Checkpoint.prune(saver, [thread_id])

        assert saver |> Checkpoint.list(config(thread_id)) |> Enum.map(& &1.config) ==
                 Enum.map([latest, forked, step, root], &Checkpoint.get_tuple(saver, &1).config)

        assert Checkpoint.get_tuple(saver, snapshot) == nil
        assert Checkpoint.get_tuple(saver, older_branch) == nil
        assert Checkpoint.get_delta_channel_history(saver, latest, ["items"]) == history
      end

      test "prune keeps every delta channel's history and makes the first checkpoint it keeps a root",
           %{saver: saver} do
        thread_id = unique("thread")
        first = put_step!(saver, config(thread_id), %{}, %{"a" => ["a0"], "b" => ["b0"]})
        b_snapshot = put_step!(saver, first, %{"b" => %DeltaSnapshot{value: ["b0", "b1"]}}, %{"a" => ["a1"]})
        middle = put_step!(saver, b_snapshot, %{}, %{"a" => ["a2"], "b" => ["b2"]})

        a_snapshot =
          put_step!(saver, middle, %{"a" => %DeltaSnapshot{value: ["a0", "a1", "a2", "a3"]}}, %{"b" => ["b3"]})

        latest = put_step!(saver, a_snapshot, %{}, %{"a" => ["a4"], "b" => ["b4"]})
        history = Checkpoint.get_delta_channel_history(saver, latest, ["a", "b"])

        assert :ok = Checkpoint.prune(saver, [thread_id])

        assert Checkpoint.get_tuple(saver, first) == nil
        assert %{parent_config: nil} = Checkpoint.get_tuple(saver, b_snapshot)
        assert Checkpoint.get_delta_channel_history(saver, latest, ["a", "b"]) == history
        assert {:ok, _config} = Checkpoint.fork_at(saver, latest, unique("thread"))
      end

      test "prune keeps a delta channel's writes saved only as a paused step's pending writes", %{saver: saver} do
        thread_id = unique("thread")
        counters = %{"counters_since_delta_snapshot" => %{"items" => [0, 1]}}
        paused = put_checkpoint!(saver, config(thread_id), %{}, metadata(step: 0) |> Map.merge(counters))
        :ok = Checkpoint.put_writes(saver, paused, [{"items", "finished-task"}], unique("task"))
        continued = put_checkpoint!(saver, paused, %{}, metadata(step: 1) |> Map.merge(counters))
        latest = put_checkpoint!(saver, continued, %{}, metadata(step: 2) |> Map.merge(counters))

        assert :ok = Checkpoint.prune(saver, [thread_id])

        assert %{"items" => %{writes: [%PendingWrite{value: "finished-task"}]}} =
                 Checkpoint.get_delta_channel_history(saver, latest, ["items"])
      end

      test "prune drops a subgraph call's namespace when it deletes the checkpoint the call belongs to",
           %{saver: saver} do
        thread_id = unique("thread")

        call = fn root, namespace ->
          %{
            "configurable" => %{
              "thread_id" => thread_id,
              "checkpoint_ns" => namespace,
              "checkpoint_map" => %{"" => root_id(root)}
            }
          }
        end

        first = put_checkpoint!(saver, config(thread_id), %{"value" => 1}, metadata(step: 0))
        put_checkpoint!(saver, call.(first, "sub:task_a"), %{"n" => 1}, metadata(step: 0))
        latest = put_checkpoint!(saver, first, %{"value" => 2}, metadata(step: 1))
        paused_call = put_checkpoint!(saver, call.(latest, "sub:task_b"), %{"n" => 2}, metadata(step: 0))

        assert :ok = Checkpoint.prune(saver, [thread_id])

        assert [] = Checkpoint.list(saver, config(thread_id, checkpoint_ns: "sub:task_a"))

        assert [%{config: %{"configurable" => %{"checkpoint_id" => paused_id}}}] =
                 Checkpoint.list(saver, config(thread_id, checkpoint_ns: "sub:task_b"))

        assert paused_id == root_id(paused_call)
        assert [%{metadata: %{"step" => 1}}] = Checkpoint.list(saver, config(thread_id))
      end

      test "delete_for_runs leaves a checkpoint whose parent it deleted forkable", %{saver: saver} do
        thread_id = unique("thread")
        [kept_run, deleted_run] = [unique("run"), unique("run")]

        first = put_checkpoint!(saver, config(thread_id), %{"value" => 1}, metadata(step: 0, run_id: kept_run))

        deleted =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(first)),
            %{"value" => 2},
            metadata(step: 1, run_id: deleted_run)
          )

        latest =
          put_checkpoint!(
            saver,
            config(thread_id, checkpoint_id: root_id(deleted)),
            %{"value" => 3},
            metadata(step: 2, run_id: kept_run)
          )

        assert :ok = Checkpoint.delete_for_runs(saver, [deleted_run])
        assert %{parent_config: nil} = Checkpoint.get_tuple(saver, latest)
        assert %{parent_config: nil} = Checkpoint.get_tuple(saver, first)

        assert {:ok, forked} = Checkpoint.fork_at(saver, latest, unique("thread"))
        assert %{checkpoint: %{"channel_values" => %{"value" => 3}}} = Checkpoint.get_tuple(saver, forked)
      end

      test "delete_for_runs refuses to delete delta history that a later run reads", %{saver: saver} do
        thread_id = unique("thread")
        [first_run, second_run] = [unique("run"), unique("run")]

        first_input = put_step!(saver, config(thread_id), %{}, %{"items" => ["first"]}, run_id: first_run)
        first_step = put_step!(saver, first_input, %{}, %{"items" => ["n"]}, run_id: first_run)
        second_input = put_step!(saver, first_step, %{}, %{"items" => ["second"]}, run_id: second_run)
        put_step!(saver, second_input, %{}, %{"items" => ["n"]}, run_id: second_run)

        assert {:error, %Error{type: :delta_history_in_use}} = Checkpoint.delete_for_runs(saver, [first_run])
        assert length(Checkpoint.list(saver, config(thread_id))) == 4

        assert :ok = Checkpoint.delete_for_runs(saver, [second_run])
        assert [%{metadata: %{"run_id" => ^first_run}}, _first_input] = Checkpoint.list(saver, config(thread_id))

        other_thread = unique("thread")
        later_run = unique("run")
        plain = put_checkpoint!(saver, config(other_thread), %{"value" => 1}, metadata(step: 0, run_id: later_run))
        later_input = put_step!(saver, config(thread_id), %{}, %{"items" => ["later"]}, run_id: later_run)
        put_step!(saver, later_input, %{}, %{"items" => ["n"]}, run_id: unique("run"))

        # One of the run's threads still reads the run's history, so none of
        # its checkpoints go, on any thread.
        assert {:error, %Error{type: :delta_history_in_use}} = Checkpoint.delete_for_runs(saver, [later_run])
        assert %{metadata: %{"run_id" => ^later_run}} = Checkpoint.get_tuple(saver, plain)

        snapshot_thread = unique("thread")
        old_run = unique("run")
        old = put_step!(saver, config(snapshot_thread), %{}, %{"items" => ["old"]}, run_id: old_run)
        put_step!(saver, old, %{"items" => %DeltaSnapshot{value: ["old", "new"]}}, %{}, run_id: unique("run"))

        assert :ok = Checkpoint.delete_for_runs(saver, [old_run])
        assert Checkpoint.get_tuple(saver, old) == nil
      end

      if adapter in [:postgres, :sqlite] do
        test "a prefix of nil, false or \"\" names no schema, as in the migration" do
          for prefix <- [nil, false, ""] do
            saver = new_saver(unquote(adapter), prefix: prefix)
            stored = put_checkpoint!(saver, config(), %{"step" => 1}, metadata(step: 0))

            assert %{checkpoint: %{"channel_values" => %{"step" => 1}}} = Checkpoint.get_tuple(saver, stored)
            assert [_tuple] = Checkpoint.list(saver, stored)
          end
        end
      end
    end
  end

  defp new_saver(adapter, opts \\ [])

  defp new_saver(:ets, _opts), do: ETS.new()
  defp new_saver(:postgres_encrypted, _opts), do: new_saver(:postgres, serialization: encryption())
  defp new_saver(:sqlite_encrypted, _opts), do: new_saver(:sqlite, serialization: encryption())

  defp new_saver(:postgres, opts) do
    assert LivePostgres.available?()

    checkpoints = LivePostgres.unique_table("bw_conformance_checkpoints")
    writes = LivePostgres.unique_table("bw_conformance_writes")
    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = LivePostgres.migrate(migration)

    on_exit(fn ->
      LivePostgres.drop_tables([writes, checkpoints])
      LivePostgres.clear_migration(version)
    end)

    Ecto.new([repo: PostgresRepo, checkpoints_table: checkpoints, writes_table: writes] ++ opts)
  end

  defp new_saver(:sqlite, opts) do
    checkpoints = LiveSQLite.unique_table("bw_conformance_checkpoints")
    writes = LiveSQLite.unique_table("bw_conformance_writes")

    migration = [
      repo: SQLiteRepo,
      adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]
    ]

    version = LiveSQLite.migrate(migration)

    on_exit(fn ->
      LiveSQLite.drop_tables([writes, checkpoints])
      LiveSQLite.clear_migration(version)
    end)

    Ecto.new([repo: SQLiteRepo, checkpoints_table: checkpoints, writes_table: writes] ++ opts)
  end

  defp encryption, do: [codec: BeamWeaver.Serialization.Encrypted, encryption_key: :crypto.strong_rand_bytes(32)]

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

  defp put_step!(saver, config, channel_values, channel_deltas, metadata \\ []) do
    checkpoint = checkpoint(channel_values: channel_values, channel_deltas: channel_deltas)
    {:ok, stored} = Checkpoint.put(saver, config, checkpoint, metadata(metadata), %{})
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
