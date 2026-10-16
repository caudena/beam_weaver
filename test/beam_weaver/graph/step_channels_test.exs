defmodule BeamWeaver.Graph.StepChannelsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.AnyValue
  alias BeamWeaver.Graph.Channels.EphemeralValue
  alias BeamWeaver.Graph.Channels.Topic
  alias BeamWeaver.Graph.Compiled

  defp chain(graph, nodes) do
    [Graph.start() | nodes]
    |> Enum.concat([Graph.end_node()])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [from, to], graph -> Graph.add_edge(graph, from, to) end)
  end

  test "an ephemeral value is read by the next step and cleared after it" do
    parent = self()

    graph =
      Graph.new(state_schema: %{signal: Graph.channel(EphemeralValue)})
      |> Graph.add_node(:raise_signal, fn _state -> %{signal: :refund} end)
      |> Graph.add_node(:next_step, fn state ->
        send(parent, {:next_step, state[:signal]})
        %{handled: true}
      end)
      |> Graph.add_node(:later_step, fn state ->
        send(parent, {:later_step, state[:signal]})
        %{done: true}
      end)
      |> chain([:raise_signal, :next_step, :later_step])
      |> Graph.compile!()

    assert {:ok, result} = Compiled.invoke(graph, %{})
    assert result == %{handled: true, done: true}
    assert_receive {:next_step, :refund}
    assert_receive {:later_step, nil}
  end

  test "an ephemeral value written again stays for another step" do
    parent = self()

    graph =
      Graph.new(state_schema: %{signal: Graph.channel(EphemeralValue)})
      |> Graph.add_node(:first, fn _state -> %{signal: 1} end)
      |> Graph.add_node(:second, fn state -> %{signal: state.signal + 1} end)
      |> Graph.add_node(:third, fn state ->
        send(parent, {:third, state[:signal]})
        %{}
      end)
      |> chain([:first, :second, :third])
      |> Graph.compile!()

    assert {:ok, result} = Compiled.invoke(graph, %{})
    refute Map.has_key?(result, :signal)
    assert_receive {:third, 2}
  end

  test "a topic without accumulate holds one step's writes; any value keeps its value" do
    parent = self()

    graph =
      Graph.new(
        state_schema: %{
          events: Graph.channel(Topic),
          status: Graph.channel(AnyValue)
        }
      )
      |> Graph.add_node(:emit, fn _state -> %{events: ["refunded"], status: :open} end)
      |> Graph.add_node(:read, fn state ->
        send(parent, {:read, state[:events]})
        %{}
      end)
      |> Graph.add_node(:later, fn state ->
        send(parent, {:later, state[:events], state[:status]})
        %{}
      end)
      |> chain([:emit, :read, :later])
      |> Graph.compile!()

    assert {:ok, %{status: :open} = result} = Compiled.invoke(graph, %{})
    refute Map.has_key?(result, :events)
    assert_receive {:read, ["refunded"]}
    assert_receive {:later, nil, :open}
  end
end
