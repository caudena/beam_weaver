defmodule BeamWeaver.Cache.ETSTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Cache
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error

  test "ETS cache supports namespace, metadata, delete, and clear" do
    cache = Cache.ETS.new(visibility: :private)

    assert :miss = Cache.lookup(cache, [:tenant, 1], "key")
    assert :ok = Cache.put(cache, [:tenant, 1], "key", "value", metadata: %{model: "fake"})
    assert {:hit, "value", %{model: "fake"}} = Cache.lookup(cache, [:tenant, 1], "key")
    assert :miss = Cache.lookup(cache, [:tenant, 2], "key")

    assert :ok = Cache.delete(cache, [:tenant, 1], "key")
    assert :miss = Cache.lookup(cache, [:tenant, 1], "key")

    assert :ok = Cache.put(cache, :a, "key", "a")
    assert :ok = Cache.put(cache, :b, "key", "b")
    assert :ok = Cache.clear(cache, :a)
    assert :miss = Cache.lookup(cache, :a, "key")
    assert {:hit, "b", %{}} = Cache.lookup(cache, :b, "key")
  end

  test "ETS cache clear without namespace clears all entries" do
    # Upstream reference:
    cache = Cache.ETS.new(visibility: :private)

    assert :ok = Cache.put(cache, :a, "key", "a")
    assert :ok = Cache.put(cache, :b, "key", "b")
    assert :ok = Cache.clear(cache)

    assert :miss = Cache.lookup(cache, :a, "key")
    assert :miss = Cache.lookup(cache, :b, "key")
  end

  test "update alias and async helpers run through the public cache contract" do
    cache = Cache.ETS.new()

    assert :ok = Cache.update(cache, :async, "key", "value")
    assert {:hit, "value", %{}} = Cache.async_lookup(cache, :async, "key") |> Async.await()

    assert :ok = Cache.async_update(cache, :async, "key", "new") |> Async.await()
    assert {:hit, "new", %{}} = Cache.lookup(cache, :async, "key")

    assert :ok = Cache.async_delete(cache, :async, "key") |> Async.await()
    assert :miss = Cache.lookup(cache, :async, "key")

    assert :ok = Cache.async_put(cache, :async, "other", "kept") |> Async.await()
    assert :ok = Cache.async_clear(cache, :async) |> Async.await()
    assert :miss = Cache.lookup(cache, :async, "other")
  end

  test "batch cache facade maps full keys to explicit adapter operations" do
    cache = Cache.ETS.new(visibility: :private)
    key_a = {{"graph", "node"}, "a"}
    key_b = {{"graph", "other"}, "b"}
    key_c = {{"graph", "node"}, "c"}

    assert %{} = Cache.get_many(cache, [key_a])

    assert :ok =
             Cache.set_many(cache, %{
               key_a => {"value-a", nil},
               key_b => {"value-b", nil},
               key_c => {"expired", 1}
             })

    assert %{^key_a => "value-a", ^key_b => "value-b", ^key_c => "expired"} =
             Cache.get_many(cache, [key_a, key_b, key_c])

    Process.sleep(1_050)
    assert %{^key_a => "value-a", ^key_b => "value-b"} = Cache.get_many(cache, [key_a, key_b])
    refute Map.has_key?(Cache.get_many(cache, [key_c]), key_c)

    assert :ok = Cache.clear_many(cache, [{"graph", "node"}])
    assert %{^key_b => "value-b"} = Cache.get_many(cache, [key_a, key_b])

    assert :ok = Cache.clear_many(cache)
    assert %{} = Cache.get_many(cache, [key_b])
  end

  test "batch cache facade has Task-backed async helpers" do
    cache = Cache.ETS.new()
    key = {["async", "node"], "key"}

    assert :ok = Cache.async_set_many(cache, %{key => {"value", nil}}) |> Async.await()
    assert %{^key => "value"} = Cache.async_get_many(cache, [key]) |> Async.await()
    assert :ok = Cache.async_clear_many(cache, [["async", "node"]]) |> Async.await()
    assert %{} = Cache.get_many(cache, [key])
  end

  test "ETS cache expires TTL entries" do
    cache = Cache.ETS.new(visibility: :private)

    assert :ok = Cache.put(cache, :ttl, "key", "value", ttl: 1)
    Process.sleep(5)
    assert :miss = Cache.lookup(cache, :ttl, "key")
  end

  test "ETS cache non-positive TTL is treated as no expiration" do
    cache = Cache.ETS.new(visibility: :private)

    assert :ok = Cache.put(cache, :ttl, "zero", "kept", ttl: 0)
    assert :ok = Cache.put(cache, :ttl, "negative", "kept", ttl: -1)
    Process.sleep(5)

    assert {:hit, "kept", %{}} = Cache.lookup(cache, :ttl, "zero")
    assert {:hit, "kept", %{}} = Cache.lookup(cache, :ttl, "negative")
  end

  test "ETS cache evicts oldest entries when max_entries is reached" do
    cache = Cache.ETS.new(visibility: :private, max_entries: 2)

    assert :ok = Cache.update(cache, :llm, {"prompt1", "llm"}, ["generation1"])
    Process.sleep(2)
    assert :ok = Cache.update(cache, :llm, {"prompt2", "llm"}, ["generation2"])
    Process.sleep(2)
    assert :ok = Cache.update(cache, :llm, {"prompt3", "llm"}, ["generation3"])

    assert :miss = Cache.lookup(cache, :llm, {"prompt1", "llm"})
    assert {:hit, ["generation2"], %{}} = Cache.lookup(cache, :llm, {"prompt2", "llm"})
    assert {:hit, ["generation3"], %{}} = Cache.lookup(cache, :llm, {"prompt3", "llm"})

    assert_raise ArgumentError, "max_entries must be a positive integer", fn ->
      Cache.ETS.new(max_entries: 0)
    end
  end

  test "ETS cache max_entries pruning stays bounded under concurrent puts" do
    cache = Cache.ETS.new(max_entries: 5)

    1..50
    |> Enum.map(fn index ->
      Task.async(fn -> Cache.put(cache, :concurrent, index, index) end)
    end)
    |> Task.await_many(5_000)

    assert :ets.info(cache.table, :size) <= 5
  end

  test "cache helpers reject non-adapter globals" do
    assert {:error, %Error{type: :explicit_cache_required}} = Cache.lookup(true, :ns, :key)
    assert {:error, %Error{type: :invalid_cache}} = Cache.lookup(%{}, :ns, :key)
  end

  test "stable keys are deterministic for map order and never deserialize terms" do
    assert Cache.stable_key(%{a: 1, b: [2, 3]}) ==
             Cache.stable_key(%{b: [2, 3], a: 1})
  end
end
