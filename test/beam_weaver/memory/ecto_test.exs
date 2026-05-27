defmodule BeamWeaver.Memory.EctoTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Memory
  alias BeamWeaver.Memory.Ecto
  alias BeamWeaver.Memory.FakeSQL

  test "uses the memory store contract through an Ecto/Postgres query boundary" do
    {:ok, repo} = FakeSQL.start_link()
    store = Ecto.new(repo: repo, query_module: FakeSQL)

    assert {:ok, item} =
             Memory.put(store, [:users, "u1"], :profile, %{name: "Ada"}, metadata: %{kind: "profile"})

    assert item.namespace == ["users", "u1"]
    assert item.key == "profile"

    assert {:ok, %{value: %{name: "Ada"}}} = Memory.get(store, [:users, "u1"], :profile)
    assert [%{namespace: ["users", "u1"]}] = Memory.search(store, [:users])
    assert [["users", "u1"]] = Memory.list_namespaces(store, prefix: ["users"])

    assert :ok = Memory.delete(store, [:users, "u1"], :profile)
    assert Memory.get(store, [:users, "u1"], :profile) == :error
  end

  test "caller-supervised TTL sweeper removes expired rows through the adapter boundary" do
    {:ok, repo} = FakeSQL.start_link()
    store = Ecto.new(repo: repo, query_module: FakeSQL)

    assert {:ok, _item} = Memory.put(store, [:ttl], :short, %{value: true}, ttl: 0.0001)
    assert 1 = Agent.get(repo, &map_size/1)

    assert {:ok, sweeper} = Ecto.start_ttl_sweeper(store, interval: 10)
    Process.sleep(30)
    assert :ok = Ecto.stop_ttl_sweeper(sweeper)

    assert 0 = Agent.get(repo, &map_size/1)
  end
end
