defmodule BeamWeaver.Memory.ETSTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Memory
  alias BeamWeaver.Memory.ETS

  test "stores, filters, searches, and deletes namespaced memory items" do
    store = ETS.new()

    assert {:ok, first} =
             Memory.put(store, [:users, "u1"], :preference, %{style: "technical"}, metadata: %{kind: "preference"})

    assert first.namespace == ["users", "u1"]
    assert first.key == "preference"

    assert {:ok, _second} =
             Memory.put(store, [:users, "u2"], :preference, %{style: "brief"}, metadata: %{kind: "preference"})

    assert {:ok, item} = Memory.get(store, [:users, "u1"], :preference)
    assert item.value == %{style: "technical"}

    assert store
           |> Memory.search([:users], filter: %{kind: "preference"})
           |> Enum.map(& &1.namespace)
           |> Enum.sort() == [["users", "u1"], ["users", "u2"]]

    assert [%{namespace: ["users", "u1"]}] = Memory.search(store, [:users], query: "technical")
    assert [["users", "u1"], ["users", "u2"]] = Memory.list_namespaces(store, prefix: ["users"])

    assert :ok = Memory.delete(store, [:users, "u1"], :preference)
    assert Memory.get(store, [:users, "u1"], :preference) == :error
  end
end
