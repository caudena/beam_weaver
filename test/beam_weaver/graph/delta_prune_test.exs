defmodule BeamWeaver.Graph.DeltaPruneTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Compiled

  describe "prune keeps a thread's state" do
    test "with delta channels on different snapshot cadences" do
      saver = CheckpointETS.new()

      graph =
        Graph.new(
          state_schema: %{
            often: Graph.channel({DeltaChannel, &append/2}, snapshot_frequency: 2),
            once: Graph.channel({DeltaChannel, &append/2})
          }
        )
        |> Graph.add_node(:write, fn _state -> %{often: ["x"]} end)
        |> Graph.add_edge(Graph.start(), :write)
        |> Graph.add_edge(:write, Graph.end_node())
        |> Graph.compile!(checkpointer: saver)

      config = thread()
      {:ok, _state} = Compiled.invoke(graph, %{often: ["in"], once: ["kept"]}, config: config)
      for _turn <- 1..3, do: {:ok, _state} = Compiled.invoke(graph, %{often: ["in"]}, config: config)
      {:ok, before} = Compiled.get_state(graph, config)

      assert :ok = Checkpoint.prune(saver, [thread_id(config)])
      assert {:ok, %{values: values}} = Compiled.get_state(graph, config)
      assert values == before.values
      assert values.once == ["kept"]
    end

    test "with a delta write saved only by a finished node of a paused step" do
      saver = CheckpointETS.new()

      graph =
        Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, &append/2}), answer: nil})
        |> Graph.add_node(:write, fn _state -> %{items: "written"} end)
        |> Graph.add_node(:ask, fn _state -> %{answer: Graph.interrupt("Refund it?")} end)
        |> Graph.add_edge(Graph.start(), :write)
        |> Graph.add_edge(Graph.start(), :ask)
        |> Graph.compile!(checkpointer: saver)

      config = thread()
      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{answer: "none"}, config: config)
      assert {:ok, %{items: ["written"], answer: "yes"}} = Compiled.resume(graph, "yes", config: config)

      assert :ok = Checkpoint.prune(saver, [thread_id(config)])
      assert {:ok, %{values: %{items: ["written"]}}} = Compiled.get_state(graph, config)
    end

    test "after time travel forked it" do
      saver = CheckpointETS.new()

      graph =
        Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, &append/2}, snapshot_frequency: 4)})
        |> Graph.add_node(:write, fn _state -> %{items: "w"} end)
        |> Graph.add_edge(Graph.start(), :write)
        |> Graph.add_edge(:write, Graph.end_node())
        |> Graph.compile!(checkpointer: saver)

      config = thread()
      {:ok, _state} = Compiled.invoke(graph, %{items: "t1"}, config: config)
      fork = graph |> Compiled.get_state_history(config) |> List.first()
      {:ok, _state} = Compiled.invoke(graph, %{items: "t2"}, config: config)
      {:ok, _config} = Compiled.update_state(graph, fork.config, %{items: "fork"})

      assert :ok = Checkpoint.prune(saver, [thread_id(config)])
      assert {:ok, %{values: %{items: ~w(t1 w fork)}}} = Compiled.get_state(graph, config)
    end
  end

  test "prune drops the checkpoints of finished subgraph calls" do
    saver = CheckpointETS.new()

    child =
      Graph.new()
      |> Graph.add_reducer(:count, &+/2)
      |> Graph.add_node(:add, fn _state -> %{count: 1} end)
      |> Graph.add_edge(Graph.start(), :add)
      |> Graph.compile!()

    parent =
      Graph.new()
      |> Graph.add_reducer(:count, &+/2)
      |> Graph.add_node(:call, child)
      |> Graph.add_edge(Graph.start(), :call)
      |> Graph.compile!(checkpointer: saver)

    config = thread()
    for _run <- 1..3, do: {:ok, _state} = Compiled.invoke(parent, %{count: 0}, config: config)

    assert :ok = Checkpoint.prune(saver, [thread_id(config)])

    assert saver
           |> Checkpoint.list(%{"configurable" => %{"thread_id" => thread_id(config)}})
           |> Enum.map(& &1.config["configurable"]["checkpoint_ns"]) == [""]
  end

  test "delete_for_runs keeps the delta history later runs read" do
    saver = CheckpointETS.new()

    graph =
      Graph.new(state_schema: %{items: Graph.channel({DeltaChannel, &append/2})})
      |> Graph.add_node(:write, fn _state -> %{items: "n"} end)
      |> Graph.add_edge(Graph.start(), :write)
      |> Graph.add_edge(:write, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)

    config = thread()
    {:ok, _state} = Compiled.invoke(graph, %{items: "run1"}, config: config, run_id: "run-1")
    {:ok, _state} = Compiled.invoke(graph, %{items: "run2"}, config: config, run_id: "run-2")

    assert {:error, %Error{type: :delta_history_in_use}} = Checkpoint.delete_for_runs(saver, ["run-1"])
    assert {:ok, %{values: %{items: ~w(run1 n run2 n)}}} = Compiled.get_state(graph, config)

    assert :ok = Checkpoint.delete_for_runs(saver, ["run-2"])
    assert {:ok, %{values: %{items: ~w(run1 n)}}} = Compiled.get_state(graph, config)
  end

  defp append(state, writes), do: Enum.reduce(writes, state, &(&2 ++ List.wrap(&1)))

  defp thread, do: %{"configurable" => %{"thread_id" => "delta-prune-#{System.unique_integer([:positive])}"}}
  defp thread_id(config), do: config["configurable"]["thread_id"]
end
