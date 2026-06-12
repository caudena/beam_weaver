defmodule BeamWeaver.Agent.DSLGraphDAGTest do
  use ExUnit.Case, async: true

  defmodule ReviewPipeline do
    use BeamWeaver.Agent

    node(:draft, fn _state -> %{status: :needs_revision, attempt: 1} end)
    node(:revise, fn _state -> %{revised: true} end)
    node(:final, fn _state -> %{final: true} end)

    edge(BeamWeaver.Graph.start(), :draft)
    edge(:draft, :revise, when: %{status: :needs_revision, attempt: 1..2})
    edge(:draft, :final, default: true)
    edge(:revise, BeamWeaver.Graph.end_node())
    edge(:final, BeamWeaver.Graph.end_node())
  end

  test "Agent DSL edge options mirror Graph DAG options" do
    assert {:ok, %{revised: true}} = ReviewPipeline.invoke(%{})
  end
end
