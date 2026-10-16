defmodule BeamWeaver.Memory.ETSTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Memory
  alias BeamWeaver.Memory.ETS
  alias BeamWeaver.Memory.GetOp
  alias BeamWeaver.Memory.ListNamespacesOp
  alias BeamWeaver.Memory.MatchCondition

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

  test "list_namespaces batch op ignores unknown match-condition types instead of crashing" do
    store = ETS.new()

    assert {:ok, _} = Memory.put(store, [:users, "u1"], :preference, %{style: "technical"})
    assert {:ok, _} = Memory.put(store, [:users, "u2"], :preference, %{style: "brief"})

    op = %ListNamespacesOp{
      match_conditions: [
        %MatchCondition{type: :prefix, path: ["users"]},
        %MatchCondition{type: :exact, path: ["users"]}
      ]
    }

    assert [[["users", "u1"], ["users", "u2"]]] = Memory.batch(store, [op])
  end

  test "a read that refreshes a record never reverts a put that runs at the same time" do
    store = ETS.new(default_ttl: 60, refresh_ttl: true)
    assert {:ok, _item} = Memory.put(store, ["notes"], "k", %{"v" => 0})

    readers = for _reader <- 1..4, do: Task.async(fn -> read_until_stopped(store) end)

    reverted =
      Enum.count(1..5_000, fn version ->
        {:ok, _item} = Memory.put(store, ["notes"], "k", %{"v" => version})
        [%{value: %{"v" => stored}}] = Memory.batch(store, [%GetOp{namespace: ["notes"], key: "k", refresh_ttl: false}])
        stored != version
      end)

    Enum.each(readers, &send(&1.pid, :stop))
    Enum.each(readers, &Task.await/1)

    assert reverted == 0
    assert {:ok, %{value: %{"v" => 5_000}}} = Memory.get(store, ["notes"], "k")
  end

  test "refresh_ttl: nil is the default, false, and other values raise" do
    assert %ETS{refresh_ttl: false} = ETS.new(refresh_ttl: nil)
    assert_raise ArgumentError, ~r/:refresh_ttl/, fn -> ETS.new(refresh_ttl: "yes") end
  end

  defp read_until_stopped(store) do
    receive do
      :stop -> :ok
    after
      0 ->
        {:ok, _item} = Memory.get(store, ["notes"], "k")
        read_until_stopped(store)
    end
  end
end
