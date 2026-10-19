defmodule BeamWeaver.Graph.CheckpointReadsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Graph.Compiled

  describe "a run reads its thread's checkpoint" do
    test "once when it starts, not again for each checkpoint it writes" do
      graph = Graph.compile!(sequential(5), checkpointer: CheckpointETS.new())
      config = thread("reads-sequential-#{System.unique_integer([:positive])}")
      count_reads(config)

      assert {:ok, %{count: 5}} = Compiled.invoke(graph, %{count: 0}, config: config)
      assert reads() == 1

      assert {:ok, %{count: 10}} = Compiled.invoke(graph, %{count: 5}, config: config)
      assert reads() == 1
    end

    test "on a resume, to find the pause it answers and the checkpoint it continues, not for each step" do
      graph =
        Graph.compile!(sequential(4), checkpointer: CheckpointETS.new(), interrupt_before: [:step_3])

      config = thread("reads-resume-#{System.unique_integer([:positive])}")
      count_reads(config)

      assert {:interrupted, %{nodes: ["step_3"]}} = Compiled.invoke(graph, %{count: 0}, config: config)
      assert reads() == 1

      assert {:ok, %{count: 4}} = Compiled.resume(graph, nil, config: config)
      assert reads() == 3
    end
  end

  test "delta snapshots come every few updates, counted across steps, runs and updates" do
    reducer = fn items, writes -> items ++ List.wrap(writes) end

    graph =
      Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, reducer}, snapshot_frequency: 3)})
      |> Graph.add_node(:first, fn _state -> %{items: "first"} end)
      |> Graph.add_node(:second, fn _state -> %{items: "second"} end)
      |> Graph.add_edge(Graph.start(), :first)
      |> Graph.add_edge(:first, :second)
      |> Graph.add_edge(:second, Graph.end_node())
      |> Graph.compile!(checkpointer: CheckpointETS.new())

    config = thread("delta-snapshots-#{System.unique_integer([:positive])}")

    assert {:ok, _state} = Compiled.invoke(graph, %{items: "a"}, config: config)
    assert {:ok, _state} = Compiled.invoke(graph, %{items: "b"}, config: config)
    assert {:ok, _config} = Compiled.update_state(graph, config, %{items: "update"})
    assert {:ok, %{items: items}} = Compiled.invoke(graph, %{items: "c"}, config: config)

    assert items == ~w(a first second b first second update c first second)

    snapshots =
      graph
      |> Compiled.get_state_history(config)
      |> Enum.reverse()
      |> Enum.map(fn snapshot ->
        {snapshot.metadata["source"], snapshot.metadata["counters_since_delta_snapshot"]["items"]}
      end)

    assert snapshots == [
             {"input", [1, 1]},
             {"loop", [2, 2]},
             {"loop", [0, 0]},
             {"input", [1, 1]},
             {"loop", [2, 2]},
             {"loop", [0, 0]},
             {"update", [1, 1]},
             {"input", [2, 2]},
             {"loop", [0, 0]},
             {"loop", [1, 1]}
           ]

    snapshot_steps =
      for %{metadata: metadata} = snapshot <- Enum.reverse(Compiled.get_state_history(graph, config)),
          snapshot_saved?(graph, snapshot),
          do: {metadata["source"], metadata["step"]}

    assert snapshot_steps == [{"loop", 1}, {"loop", 1}, {"loop", 0}]
  end

  defp snapshot_saved?(graph, snapshot) do
    %{checkpoint: %{"channel_values" => values}} =
      BeamWeaver.Checkpoint.get_tuple(graph.checkpointer, snapshot.config)

    match?(%DeltaSnapshot{}, Map.get(values, :items, Map.get(values, "items")))
  end

  defp sequential(count) do
    names = Enum.map(1..count, &:"step_#{&1}")

    graph =
      Enum.reduce(names, Graph.new(), fn name, graph ->
        Graph.add_node(graph, name, fn %{count: count} -> %{count: count + 1} end)
      end)

    {graph, last} =
      Enum.reduce(names, {graph, Graph.start()}, fn name, {graph, previous} ->
        {Graph.add_edge(graph, previous, name), name}
      end)

    Graph.add_edge(graph, last, Graph.end_node())
  end

  # Counts the saver reads of the thread's checkpoints since the last call.
  defp count_reads(config) do
    thread_id = config["configurable"]["thread_id"]
    handler = {__MODULE__, thread_id}

    :ok =
      :telemetry.attach(
        handler,
        [:beam_weaver, :checkpoint, :fetch_tuple],
        &__MODULE__.handle_read/4,
        {self(), thread_id}
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

  defp thread(id), do: %{"configurable" => %{"thread_id" => id}}
end
