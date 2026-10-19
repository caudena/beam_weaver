defmodule BeamWeaver.Graph.EmptyCheckpointIdTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled

  setup do
    graph =
      Graph.new()
      |> Graph.add_reducer(:items, fn current, update -> List.wrap(current) ++ List.wrap(update) end)
      |> Graph.add_node(:write, fn _state -> %{items: "w"} end)
      |> Graph.add_edge(Graph.start(), :write)
      |> Graph.add_edge(:write, Graph.end_node())
      |> Graph.compile!(checkpointer: CheckpointETS.new())

    thread_id = "t#{System.unique_integer([:positive])}"
    config = %{"configurable" => %{"thread_id" => thread_id}}
    assert {:ok, %{items: ["t1", "w"]}} = Compiled.invoke(graph, %{items: "t1"}, config: config)

    {:ok, graph: graph, config: config, empty: put_in(config, ["configurable", "checkpoint_id"], "")}
  end

  test "get_state with an empty checkpoint_id reads the latest checkpoint", %{graph: graph, empty: empty} do
    assert {:ok, %{values: %{items: ["t1", "w"]}}} = Compiled.get_state(graph, empty)
  end

  test "invoke with an empty checkpoint_id continues the thread from its latest checkpoint", %{
    graph: graph,
    config: config,
    empty: empty
  } do
    assert {:ok, %{items: ["t1", "w", "t2", "w"]}} = Compiled.invoke(graph, %{items: "t2"}, config: empty)
    assert {:ok, %{values: %{items: ["t1", "w", "t2", "w"]}}} = Compiled.get_state(graph, config)
  end

  test "resume with an empty checkpoint_id answers the thread's pending interrupt" do
    graph =
      Graph.new()
      |> Graph.add_node(:ask, fn _state -> %{answer: Graph.interrupt("Refund order A-1?")} end)
      |> Graph.add_edge(Graph.start(), :ask)
      |> Graph.add_edge(:ask, Graph.end_node())
      |> Graph.compile!(checkpointer: CheckpointETS.new())

    config = %{"configurable" => %{"thread_id" => "t#{System.unique_integer([:positive])}"}}
    assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)

    empty = put_in(config, ["configurable", "checkpoint_id"], "")
    assert {:ok, %{answer: "yes"}} = Compiled.resume(graph, "yes", config: empty)
  end
end
