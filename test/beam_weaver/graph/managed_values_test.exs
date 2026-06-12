defmodule BeamWeaver.Graph.ManagedValuesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Managed.IsLastStep
  alias BeamWeaver.Graph.Managed.RemainingSteps

  test "managed values are recognized in schemas and projected into node state" do
    graph =
      Graph.new(
        state_schema: %{
          remaining_steps: Graph.managed(RemainingSteps),
          is_last_step: Graph.managed(IsLastStep)
        }
      )
      |> Graph.add_node(:inspect, fn state ->
        %{seen_remaining: state.remaining_steps, seen_last: state.is_last_step}
      end)
      |> Graph.add_edge(Graph.start(), :inspect)
      |> Graph.add_edge(:inspect, Graph.end_node())
      |> Graph.compile!()

    assert Map.has_key?(graph.graph.managed, :remaining_steps)
    assert Map.has_key?(graph.graph.managed, :is_last_step)

    assert {:ok, result} = Compiled.invoke(graph, %{}, recursion_limit: 3)
    assert result.seen_remaining == 3
    assert result.seen_last == false
    refute Map.has_key?(result, :remaining_steps)
    refute Map.has_key?(result, :is_last_step)
  end

  test "remaining step managed values count down by superstep" do
    graph =
      Graph.new(
        state_schema: %{
          remaining_steps: Graph.managed(RemainingSteps),
          is_last_step: Graph.managed(IsLastStep)
        }
      )
      |> Graph.add_node(:first, fn _state -> %{first_done: true} end)
      |> Graph.add_node(:inspect, fn state ->
        %{seen_remaining: state.remaining_steps, seen_last: state.is_last_step}
      end)
      |> Graph.add_edge(Graph.start(), :first)
      |> Graph.add_edge(:first, :inspect)
      |> Graph.add_edge(:inspect, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, result} = Compiled.invoke(graph, %{}, recursion_limit: 3)
    assert result.seen_remaining == 2
    assert result.seen_last == false
  end

  test "managed values are read-only" do
    graph =
      Graph.new(state_schema: %{remaining_steps: Graph.managed(RemainingSteps)})
      |> Graph.add_node(:bad, fn _state -> %{remaining_steps: 10} end)
      |> Graph.add_edge(Graph.start(), :bad)
      |> Graph.add_edge(:bad, Graph.end_node())
      |> Graph.compile!()

    assert {:error, %Error{type: :invalid_update, message: "managed graph values are read-only"}} =
             Compiled.invoke(graph, %{})
  end
end
