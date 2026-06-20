defmodule BeamWeaver.Graph.DeltaChannelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Graph
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Overwrite

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
end
