defmodule BeamWeaver.Graph.PrivateChannelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.LastValue
  alias BeamWeaver.Graph.Channels.UntrackedValue
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Send

  test "private channels can drive nodes but are hidden from output and checkpoints" do
    saver = CheckpointETS.new()

    graph =
      Graph.new(state_schema: %{secret: Graph.private_channel(LastValue, subscribers: [:listener])})
      |> Graph.add_node(:writer, fn _state -> %{secret: "token"} end)
      |> Graph.add_node(:listener, fn state -> %{public: "saw #{state.secret}"} end)
      |> Graph.add_edge(Graph.start(), :writer)
      |> Graph.add_edge(:listener, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)

    config = %{"configurable" => %{"thread_id" => "private-channel"}}

    assert {:ok, %{public: "saw token"}} = Compiled.invoke(graph, %{}, config: config)

    assert %{checkpoint: %{"channel_values" => values}} =
             BeamWeaver.Checkpoint.get_tuple(saver, config)

    refute Map.has_key?(values, :secret)
    refute Map.has_key?(values, "secret")
  end

  test "private and untracked values are removed from persisted send payloads" do
    saver = CheckpointETS.new()

    graph =
      Graph.new(
        state_schema: %{
          secret: Graph.private_channel(LastValue),
          temp: Graph.channel(UntrackedValue)
        }
      )
      |> Graph.add_node(:fanout, fn _state ->
        [%Send{node: :worker, update: %{secret: "hide", temp: "tmp", public: "keep"}}]
      end)
      |> Graph.add_node(:worker, fn state -> %{seen: state.public} end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:worker, Graph.end_node())
      |> Graph.compile!(checkpointer: saver, interrupt_before: [:worker])

    config = %{"configurable" => %{"thread_id" => "private-send"}}

    assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)

    assert %{checkpoint: %{"next_tasks" => [%{"update" => update}]}} =
             BeamWeaver.Checkpoint.get_tuple(saver, config)

    assert update == %{public: "keep"}
  end
end
