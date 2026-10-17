defmodule BeamWeaver.Graph.DeltaChannelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Channels.LastValue
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  test "update keeps an explicit nil overwrite instead of resetting to initial" do
    reducer = fn state, writes -> state ++ List.wrap(writes) end
    channel = DeltaChannel.new(reducer, initial: ["seed"])

    assert {:ok, updated, true} = DeltaChannel.update(channel, [Overwrite.new(nil)])
    assert {:ok, nil} = DeltaChannel.get(updated)
  end

  test "update keeps an explicit false overwrite instead of resetting to initial" do
    reducer = fn state, writes -> state ++ List.wrap(writes) end
    channel = DeltaChannel.new(reducer, initial: ["seed"])

    assert {:ok, updated, true} = DeltaChannel.update(channel, [Overwrite.new(false)])
    assert {:ok, false} = DeltaChannel.get(updated)
  end

  test "replay_writes keeps an explicit nil overwrite instead of resetting to initial" do
    reducer = fn state, writes -> state ++ List.wrap(writes) end
    channel = DeltaChannel.new(reducer, initial: ["seed"])

    pending = [%PendingWrite{task_id: "t", channel: "items", value: Overwrite.new(nil)}]

    assert {:ok, updated, true} = DeltaChannel.replay_writes(channel, pending)
    assert {:ok, nil} = DeltaChannel.get(updated)
  end

  test "snapshot frequency stores DeltaSnapshot without changing restored state" do
    saver = CheckpointETS.new()
    reducer = fn state, writes -> state ++ List.wrap(writes) end

    graph =
      Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, reducer}, snapshot_frequency: 1)})
      |> Graph.add_node(:append, fn _state -> %{items: "node"} end)
      |> Graph.add_edge(Graph.start(), :append)
      |> Graph.add_edge(:append, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)

    config = %{"configurable" => %{"thread_id" => "delta-snapshot"}}

    assert {:ok, %{items: ["input", "node"]}} =
             Compiled.invoke(graph, %{items: "input"}, config: config)

    assert %{checkpoint: %{"channel_values" => values}} = Checkpoint.get_tuple(saver, config)

    assert %DeltaSnapshot{value: ["input", "node"]} =
             Map.get(values, :items, Map.get(values, "items"))

    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert snapshot.values.items == ["input", "node"]
  end

  test "pre-migration aggregate values become DeltaChannel seeds" do
    saver = CheckpointETS.new()
    reducer = fn state, writes -> state ++ List.wrap(writes) end
    config = %{"configurable" => %{"thread_id" => "delta-migration"}}

    {:ok, stored} =
      Checkpoint.put(
        saver,
        config,
        %{
          "id" => "00000000000000000001",
          "channel_values" => %{"items" => ["old"]},
          "channel_versions" => %{"items" => 1},
          "versions_seen" => %{},
          "updated_channels" => ["items"],
          "next" => []
        },
        %{step: 0},
        %{"items" => 1}
      )

    {:ok, target} =
      Checkpoint.put(
        saver,
        stored,
        %{
          "id" => "00000000000000000002",
          "channel_values" => %{},
          "channel_versions" => %{"items" => 2},
          "versions_seen" => %{},
          "updated_channels" => ["items"],
          "next" => [],
          "channel_deltas" => %{"items" => ["new"]}
        },
        %{step: 1},
        %{"items" => 2}
      )

    graph =
      Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, reducer})})
      |> Graph.add_node(:noop, fn _state -> %{} end)
      |> Graph.add_edge(Graph.start(), :noop)
      |> Graph.add_edge(:noop, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)

    assert {:ok, snapshot} = Compiled.get_state(graph, target)
    assert snapshot.values.items == ["old", "new"]
  end

  test "map delta channel reconstructs filesystem-style writes through checkpoint history" do
    merge_files = fn state, writes ->
      Enum.reduce(writes, state, fn write, acc ->
        Enum.reduce(write, acc, fn
          {path, nil}, files -> Map.delete(files, path)
          {path, content}, files -> Map.put(files, path, content)
        end)
      end)
    end

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    saver = CheckpointETS.new()

    graph =
      Graph.new(
        state_schema: %{
          files: Graph.channel({DeltaChannel, merge_files}, initial: %{})
        }
      )
      |> Graph.add_node(:write_file, fn _state ->
        n = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
        %{files: %{"/doc_#{n}.txt" => "content for turn #{n}"}}
      end)
      |> Graph.add_edge(Graph.start(), :write_file)
      |> Graph.add_edge(:write_file, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)

    config = %{"configurable" => %{"thread_id" => "delta-map-files"}}

    for _ <- 1..3 do
      assert {:ok, _state} = Compiled.invoke(graph, %{files: %{}}, config: config)
    end

    assert {:ok, snapshot} = Compiled.get_state(graph, config)

    assert snapshot.values.files == %{
             "/doc_1.txt" => "content for turn 1",
             "/doc_2.txt" => "content for turn 2",
             "/doc_3.txt" => "content for turn 3"
           }

    assert %{checkpoint: %{"channel_values" => values}} = Checkpoint.get_tuple(saver, config)
    refute Map.has_key?(values, :files)
    refute Map.has_key?(values, "files")

    delete_graph =
      Graph.new(
        state_schema: %{
          files: Graph.channel({DeltaChannel, merge_files}, initial: %{})
        }
      )
      |> Graph.add_node(:write_file, fn _state -> %{files: %{"/doc_1.txt" => "content"}} end)
      |> Graph.add_node(:delete_file, fn _state -> %{files: %{"/doc_1.txt" => nil}} end)
      |> Graph.add_edge(Graph.start(), :write_file)
      |> Graph.add_edge(:write_file, :delete_file)
      |> Graph.add_edge(:delete_file, Graph.end_node())
      |> Graph.compile!(checkpointer: CheckpointETS.new())

    assert {:ok, %{files: %{}}} =
             Compiled.invoke(delete_graph, %{files: %{}},
               config: %{"configurable" => %{"thread_id" => "delta-map-delete"}}
             )
  end

  describe "an overwrite" do
    test "drops the other writes of its step, and the step reads the same after a reload" do
      for {first, second} <- [{:b_reset, :c_append}, {:a_append, :b_reset}] do
        saver = CheckpointETS.new()

        node = fn
          :b_reset -> fn _state -> %{items: Overwrite.new(["reset"])} end
          _append -> fn _state -> %{items: ["appended"]} end
        end

        graph =
          Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, &append/2})})
          |> Graph.add_node(:start_node, fn _state -> %{items: ["started"]} end)
          |> Graph.add_node(first, node.(first))
          |> Graph.add_node(second, node.(second))
          |> Graph.add_edge(Graph.start(), :start_node)
          |> Graph.add_edge(:start_node, first)
          |> Graph.add_edge(:start_node, second)
          |> Graph.compile!(checkpointer: saver)

        config = thread("overwrite-#{first}")

        assert {:ok, %{items: ["reset"]}} = Compiled.invoke(graph, %{items: ["input"]}, config: config)
        assert {:ok, %{values: %{items: ["reset"]}}} = Compiled.get_state(graph, config)

        assert %{checkpoint: %{"channel_deltas" => %{"items" => [%Overwrite{value: ["reset"]}]}}} =
                 Checkpoint.get_tuple(saver, config)
      end
    end

    test "replays as the writes of its checkpoint's step, which it drops" do
      channel = DeltaChannel.new(&append/2)

      writes = [
        %PendingWrite{checkpoint_id: "1", task_id: "__delta_checkpoint__", channel: "items", value: ["a"]},
        %PendingWrite{checkpoint_id: "1", task_id: "task-1", channel: "items", value: Overwrite.new(["b"])},
        %PendingWrite{checkpoint_id: "1", task_id: "task-2", channel: "items", value: ["dropped"]},
        %PendingWrite{checkpoint_id: "2", task_id: "__delta_checkpoint__", channel: "items", value: ["c"]}
      ]

      assert {:ok, replayed, true} = DeltaChannel.replay_writes(channel, writes)
      assert {:ok, ["b", "c"]} = DeltaChannel.get(replayed)
    end
  end

  describe "a step's writes" do
    test "are saved one per write, so a list or nil write reads back as written" do
      saver = CheckpointETS.new()

      graph =
        Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, &batches/2})})
        |> Graph.add_node(:list, fn _state -> %{items: ["x", "y"]} end)
        |> Graph.add_node(:none, fn _state -> %{items: nil} end)
        |> Graph.add_edge(Graph.start(), :list)
        |> Graph.add_edge(:list, :none)
        |> Graph.add_edge(:none, Graph.end_node())
        |> Graph.compile!(checkpointer: saver)

      config = thread("list-writes")
      written = [{:batch, ["in"]}, {:batch, ["x", "y"]}, {:write, nil}]

      assert {:ok, %{items: ^written}} = Compiled.invoke(graph, %{items: ["in"]}, config: config)
      assert {:ok, %{values: %{items: ^written}}} = Compiled.get_state(graph, config)

      assert [[nil], [["x", "y"]], [["in"]]] =
               saver |> Checkpoint.list(config) |> Enum.map(& &1.checkpoint["channel_deltas"]["items"])
    end

    test "from parallel nodes are saved and streamed as the list of writes" do
      saver = CheckpointETS.new()

      graph =
        Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, &batches/2})})
        |> Graph.add_node(:left, fn _state -> %{items: ["l"]} end)
        |> Graph.add_node(:right, fn _state -> %{items: "r"} end)
        |> Graph.add_edge(Graph.start(), :left)
        |> Graph.add_edge(Graph.start(), :right)
        |> Graph.compile!(checkpointer: saver)

      config = thread("parallel-writes")

      assert {:ok, events} = Compiled.stream_events(graph, %{}, config: config, stream_mode: :updates)
      assert [%Envelope{event: %Events.GraphUpdate{update: %{"left" => %{items: [["l"], "r"]}}}}] = events

      assert %{checkpoint: %{"channel_deltas" => %{"items" => [["l"], "r"]}}, metadata: metadata} =
               Checkpoint.get_tuple(saver, config)

      assert metadata["step_update"] == %{items: [["l"], "r"]}
      assert {:ok, %{values: %{items: [{:batch, ["l"]}, {:write, "r"}]}}} = Compiled.get_state(graph, config)
    end

    test "saved by earlier versions, with a list write saved as its items, read as before" do
      saver = CheckpointETS.new()
      config = thread("earlier-list-writes")

      {:ok, stored} =
        Checkpoint.put(
          saver,
          config,
          %{
            "v" => 1,
            "id" => "00000000000000000001",
            "channel_values" => %{},
            "channel_versions" => %{"items" => 1},
            "versions_seen" => %{},
            "channel_deltas" => %{"items" => ["x", "y"]}
          },
          %{step: 0},
          %{"items" => 1}
        )

      graph =
        Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, &batches/2})})
        |> Graph.add_node(:noop, fn _state -> %{} end)
        |> Graph.add_edge(Graph.start(), :noop)
        |> Graph.compile!(checkpointer: saver)

      assert {:ok, %{values: %{items: [{:write, "x"}, {:write, "y"}]}}} = Compiled.get_state(graph, stored)
    end
  end

  test "a key changed from a delta channel to a reducer keeps its value, and the next run adds to it" do
    saver = CheckpointETS.new()
    config = thread("delta-to-reducer")

    chat = fn spec ->
      Graph.new(state_schema: %{items: spec})
      |> Graph.add_node(:chat, fn state -> %{items: ["reply #{length(state.items)}"]} end)
      |> Graph.add_edge(Graph.start(), :chat)
      |> Graph.add_edge(:chat, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)
    end

    delta = chat.(Graph.channel({DeltaChannel, &append/2}, snapshot_frequency: 3))
    for turn <- 1..4, do: {:ok, _state} = Compiled.invoke(delta, %{items: ["q#{turn}"]}, config: config)
    delta_history = Compiled.get_state_history(delta, config)

    plain = chat.(Graph.channel({BinaryOperatorAggregate, &(&1 ++ List.wrap(&2))}, initial: []))

    assert {:ok, %{values: %{items: items}}} = Compiled.get_state(plain, config)
    assert items == ["q1", "reply 1", "q2", "reply 3", "q3", "reply 5", "q4", "reply 7"]

    assert Enum.map(Compiled.get_state_history(plain, config), & &1.values) ==
             Enum.map(delta_history, & &1.values)

    assert {:ok, %{items: next}} = Compiled.invoke(plain, %{items: ["q5"]}, config: config)
    assert next == items ++ ["q5", "reply 9"]
  end

  describe "reading a thread" do
    test "reads checkpoints back to a delta channel's nearest snapshot, and history reads none per checkpoint" do
      graph =
        Graph.new(
          state_schema: %{
            items: Graph.channel({DeltaChannel, &append/2}, snapshot_frequency: 4),
            unwritten: Graph.channel({DeltaChannel, &append/2})
          }
        )
        |> Graph.add_node(:write, fn _state -> %{items: ["w"]} end)
        |> Graph.add_edge(Graph.start(), :write)
        |> Graph.add_edge(:write, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("delta-reads")
      for turn <- 1..9, do: {:ok, _state} = Compiled.invoke(graph, %{items: ["t#{turn}"]}, config: config)
      count_reads(config)

      # 18 updates: a snapshot at the 16th, two checkpoints before the head.
      # The head is read, then again with those two.
      assert {:ok, %{values: %{items: items, unwritten: []}}} = Compiled.get_state(graph, config)
      assert length(items) == 18
      assert reads() == 4

      history = Compiled.get_state_history(graph, config)
      assert length(history) == 18
      assert reads() == 1
    end

    test "update_state and bulk_update_state read the checkpoint they update once" do
      graph =
        Graph.new()
        |> Graph.add_node(:write, fn _state -> %{note: "w"} end)
        |> Graph.add_edge(Graph.start(), :write)
        |> Graph.add_edge(:write, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("update-reads")
      assert {:ok, _state} = Compiled.invoke(graph, %{}, config: config)
      count_reads(config)

      assert {:ok, _config} = Compiled.update_state(graph, config, %{note: "u"})
      assert reads() == 1

      assert {:ok, _config} =
               Compiled.bulk_update_state(graph, config, [[%{note: "v"}], [%{note: "x"}], [%{note: "y"}]])

      assert reads() == 1
    end

    test "a superstep's several writes to a delta key route as the list of writes" do
      graph =
        Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, &append/2})})
        |> Graph.add_node(:collect, fn _state -> %{items: ["c"]} end)
        |> Graph.add_node(:review, fn _state -> %{items: ["reviewed"]} end)
        |> Graph.add_edge(Graph.start(), :collect)
        |> Graph.add_edge(:collect, :review, when: fn update -> update[:items] == [["x"], ["y"]] end)
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("delta-bulk-route")
      assert {:ok, %{items: ["c"]}} = Compiled.invoke(graph, %{items: []}, config: config)

      assert {:ok, _config} =
               Compiled.bulk_update_state(graph, config, [[%{items: ["x"]}, %{items: ["y"]}]], as_node: :collect)

      assert {:ok, %{next: ["review"]}} = Compiled.get_state(graph, config)
    end

    test "a history whose delta key no longer restores fails without reading every checkpoint again" do
      saver = CheckpointETS.new()

      build = fn channel ->
        Graph.new(state_schema: %{items: channel})
        |> Graph.add_node(:a, fn _state -> %{items: ["a"]} end)
        |> Graph.add_node(:b, fn _state -> %{items: ["b"]} end)
        |> Graph.add_edge(Graph.start(), :a)
        |> Graph.add_edge(Graph.start(), :b)
        |> Graph.compile!(checkpointer: saver)
      end

      config = thread("delta-history-error")
      delta = build.(Graph.channel({DeltaChannel, &append/2}))
      for turn <- 1..10, do: {:ok, _state} = Compiled.invoke(delta, %{items: ["t#{turn}"]}, config: config)

      # The key is a plain value now, which two writes in one step can't set.
      count_reads(config)

      assert {:error, %Error{type: :invalid_update}} =
               Compiled.get_state_history(build.(Graph.channel(LastValue)), config)

      assert reads() == 1
    end

    test "replaying a history calls the reducer once for the steps since the last overwrite" do
      calls = :counters.new(1, [])

      counting = fn state, writes ->
        :counters.add(calls, 1, 1)
        append(state, writes)
      end

      writes =
        for {checkpoint_id, value} <- [{"c1", "a"}, {"c2", Overwrite.new(["reset"])}, {"c3", "b"}, {"c4", "c"}] do
          %PendingWrite{checkpoint_id: checkpoint_id, task_id: DeltaChannel.step_task(), channel: "items", value: value}
        end

      channel = Channel.from_checkpoint(DeltaChannel.new(counting, key: "items"), Channel.missing())

      assert {:ok, replayed, true} = DeltaChannel.replay_writes(channel, writes)
      assert Channel.get(replayed) == {:ok, ["reset", "b", "c"]}
      assert :counters.get(calls, 1) == 1
    end

    test "gives every checkpoint of a history the values reading it alone gives" do
      saver = CheckpointETS.new()

      graph =
        Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, &append/2}, snapshot_frequency: 3)})
        |> Graph.add_node(:write, fn _state -> %{items: ["w"]} end)
        |> Graph.add_node(:ask, fn _state -> %{items: ["answer " <> Graph.interrupt("q")]} end)
        |> Graph.add_edge(Graph.start(), :write)
        |> Graph.add_edge(Graph.start(), :ask)
        |> Graph.compile!(checkpointer: saver)

      config = thread("delta-history")

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{items: ["t1"]}, config: config)
      assert {:ok, _state} = Compiled.resume(graph, "yes", config: config)
      finished = graph |> Compiled.get_state_history(config) |> List.first()
      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{items: ["t2"]}, config: config)
      assert {:ok, _state} = Compiled.resume(graph, "no", config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{items: Overwrite.new(["reset"])})
      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{items: ["fork"]}, config: finished.config)
      assert {:ok, _state} = Compiled.resume(graph, "again", config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{items: ["update"]})

      history = Compiled.get_state_history(graph, config)
      assert length(history) == 8

      for snapshot <- history do
        assert {:ok, alone} = Compiled.get_state(graph, snapshot.config)
        assert snapshot.values == alone.values
      end
    end
  end

  defp append(state, writes), do: Enum.reduce(writes, state, &(&2 ++ List.wrap(&1)))

  # Records each write: a list write as one batch.
  defp batches(state, writes) do
    Enum.reduce(writes, state, fn
      write, acc when is_list(write) -> acc ++ [{:batch, write}]
      write, acc -> acc ++ [{:write, write}]
    end)
  end

  defp count_reads(config) do
    thread_id = config["configurable"]["thread_id"]
    handler = {__MODULE__, thread_id}
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:beam_weaver, :checkpoint, :fetch_tuple],
        &__MODULE__.handle_read/4,
        {test, thread_id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def handle_read(_event, _measurements, %{thread_id: thread_id}, {pid, thread_id}), do: send(pid, :checkpoint_read)
  def handle_read(_event, _measurements, _metadata, _config), do: :ok

  defp reads(count \\ 0) do
    receive do
      :checkpoint_read -> reads(count + 1)
    after
      0 -> count
    end
  end

  defp thread(name), do: %{"configurable" => %{"thread_id" => "#{name}-#{System.unique_integer([:positive])}"}}
end
