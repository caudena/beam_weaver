defmodule BeamWeaver.Checkpoint.DeltaCompactionTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.DeltaCompaction

  describe "prune_plan/1" do
    test "deletes what the latest checkpoint doesn't read, and the first one kept becomes a root" do
      namespaces = %{"" => [record("c1", nil, 1), record("c2", "c1", 2), record("c3", "c2", 3)]}

      assert {removals, [{"", "c3"}]} = DeltaCompaction.prune_plan(namespaces)
      assert Enum.sort(removals) == [{"", "c1"}, {"", "c2"}]
    end

    test "keeps the checkpoints whose delta writes the latest one reads" do
      namespaces = %{
        "" => [
          record("c1", nil, 1, values: %{}, deltas: %{"items" => ["a"]}),
          record("c2", "c1", 2, values: %{}, deltas: %{"items" => ["b"]})
        ]
      }

      assert DeltaCompaction.prune_plan(namespaces) == {[], []}
    end
  end

  test "orphans/2 lists the remaining checkpoints whose parent goes, in its own namespace" do
    namespaces = %{
      "" => [%{id: "c1", parent_id: nil}, %{id: "c2", parent_id: "c1"}, %{id: "c3", parent_id: "c2"}],
      "review:task-1" => [%{id: "c1", parent_id: nil}, %{id: "s2", parent_id: "c1"}]
    }

    assert DeltaCompaction.orphans(namespaces, MapSet.new([{"", "c1"}])) == [{"", "c2"}]
    assert DeltaCompaction.orphans(namespaces, MapSet.new([{"", "c1"}, {"", "c2"}])) == [{"", "c3"}]
  end

  defp record(id, parent_id, commit_order, opts \\ []) do
    %{
      id: id,
      parent_id: parent_id,
      commit_order: commit_order,
      checkpoint: %{
        "channel_values" => Keyword.get(opts, :values, %{"items" => ["x"]}),
        "channel_deltas" => Keyword.get(opts, :deltas, %{})
      },
      metadata: %{},
      pending_channels: MapSet.new(),
      root_id: nil
    }
  end
end
