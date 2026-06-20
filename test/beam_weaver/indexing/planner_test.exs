defmodule BeamWeaver.Indexing.PlannerTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Indexing.Planner

  describe "plan/5 without a record manager" do
    test "collapses duplicate document ids to a single :add and marks the rest :skip" do
      docs = [
        %Document{id: "a", content: "first"},
        %Document{id: "a", content: "first"},
        %Document{id: "b", content: "second"}
      ]

      assert {:ok, result} = Planner.plan(nil, docs, "ns", false, [])

      actions = Enum.map(result.documents, & &1.action)
      assert actions == [:add, :skip, :add]

      assert result.current_ids == MapSet.new(["a", "b"])
    end
  end
end
