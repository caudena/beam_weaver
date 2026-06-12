defmodule BeamWeaver.Adapters.CapabilityTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Adapter.Introspect
  alias BeamWeaver.Adapter.Retainable
  alias BeamWeaver.Adapter.Sweepable
  alias BeamWeaver.Adapter.Transactional
  alias BeamWeaver.Cache
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Memory
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.VectorStore

  test "Sweepable removes expired ETS cache entries through the public facade" do
    cache = Cache.ETS.new(visibility: :private)

    assert :ok = Cache.put(cache, :ttl, "expired", "gone", ttl: 1)
    assert :ok = Cache.put(cache, :ttl, "fresh", "kept")
    Process.sleep(5)

    assert {:ok, 1} = Cache.sweep_expired(cache)
    assert :miss = Cache.lookup(cache, :ttl, "expired")
    assert {:hit, "kept", %{}} = Cache.lookup(cache, :ttl, "fresh")
  end

  test "Sweepable removes expired ETS memory entries through the public facade" do
    store = Memory.ETS.new(visibility: :private)

    assert {:ok, _item} = Memory.put(store, [:ttl], :expired, %{gone: true}, ttl: 0.00001)
    assert {:ok, _item} = Memory.put(store, [:ttl], :fresh, %{kept: true})
    Process.sleep(10)

    assert {:ok, 1} = Memory.sweep_expired(store)
    assert :error = Memory.get(store, [:ttl], :expired)
    assert {:ok, %{value: %{kept: true}}} = Memory.get(store, [:ttl], :fresh)
  end

  test "unsupported optional capabilities return tagged errors" do
    assert {:error, %Error{type: :unsupported_operation}} = Sweepable.sweep_expired(%{}, [])
    assert {:error, %Error{type: :unsupported_operation}} = Retainable.prune(%{}, [])
    assert {:error, %Error{type: :unsupported_operation}} = Cache.sweep_expired(%{})
    assert {:error, %Error{type: :unsupported_operation}} = Memory.sweep_expired(%{})
    assert {:error, %Error{type: :unsupported_operation}} = Cache.prune(%{})
    assert {:error, %Error{type: :unsupported_operation}} = Memory.prune(%{})
  end

  test "Retainable prunes ETS cache and memory by age and max entries" do
    cache = Cache.ETS.new(visibility: :private)

    assert :ok = Cache.put(cache, :retention, "old", "old")
    Process.sleep(10)
    cutoff = System.system_time(:millisecond)
    Process.sleep(10)
    assert :ok = Cache.put(cache, :retention, "new-1", "new-1")
    assert :ok = Cache.put(cache, :retention, "new-2", "new-2")

    assert {:ok, 1} = Cache.prune(cache, namespace: :retention, older_than_ms: cutoff)
    assert :miss = Cache.lookup(cache, :retention, "old")

    assert {:ok, 1} = Cache.prune(cache, namespace: :retention, max_entries: 1)

    remaining = [
      Cache.lookup(cache, :retention, "new-1"),
      Cache.lookup(cache, :retention, "new-2")
    ]

    assert Enum.count(remaining, &match?({:hit, _, _}, &1)) == 1

    memory = Memory.ETS.new(visibility: :private)

    assert {:ok, _} = Memory.put(memory, [:retention], :old, "old")
    Process.sleep(10)
    cutoff = DateTime.utc_now()
    Process.sleep(10)
    assert {:ok, _} = Memory.put(memory, [:retention], :new_1, "new-1")
    assert {:ok, _} = Memory.put(memory, [:retention], :new_2, "new-2")

    assert {:ok, 1} = Memory.prune(memory, namespace: ["retention"], older_than: cutoff)
    assert :error = Memory.get(memory, [:retention], :old)

    assert {:ok, 1} = Memory.prune(memory, namespace: ["retention"], max_entries: 1)

    remaining = [
      Memory.get(memory, [:retention], :new_1),
      Memory.get(memory, [:retention], :new_2)
    ]

    assert Enum.count(remaining, &match?({:ok, _}, &1)) == 1
  end

  test "Transactional executes local adapters directly" do
    assert {:ok, :done} =
             Transactional.transaction(
               Cache.ETS.new(visibility: :private),
               fn -> {:ok, :done} end,
               []
             )
  end

  test "Introspect protocol exposes adapter metadata" do
    cache = BeamWeaver.Cache.Ecto.new(repo: BeamWeaver.Test.PostgresRepo, table: "bw_cache_test")

    assert %{
             adapter: BeamWeaver.Cache.Ecto,
             table: "bw_cache_test"
           } = Introspect.metadata(cache)
  end

  test "adapter operations emit stable telemetry metadata maps" do
    handler_id = "adapter-capability-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:beam_weaver, :cache, :sweep],
        [:beam_weaver, :memory, :sweep],
        [:beam_weaver, :vector_store, :add_documents],
        [:beam_weaver, :vector_store, :similarity_search]
      ],
      &__MODULE__.handle_adapter_telemetry/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    cache = Cache.ETS.new(visibility: :private)
    assert :ok = Cache.put(cache, :ttl, "expired", "gone", ttl: 1)
    Process.sleep(5)
    assert {:ok, 1} = Cache.sweep_expired(cache)

    store = Memory.ETS.new(visibility: :private)
    assert {:ok, _item} = Memory.put(store, [:ttl], :expired, "gone", ttl: 0.00001)
    Process.sleep(10)
    assert {:ok, 1} = Memory.sweep_expired(store)

    vectors =
      VectorStore.ETS.new(
        embedding: %FakeEmbeddingModel{dimensions: 3},
        namespace: "tenant-a"
      )

    assert {:ok, [_id]} = VectorStore.add_documents(vectors, [Document.new!("alpha document")])
    assert {:ok, [_doc]} = VectorStore.similarity_search(vectors, "alpha", k: 1)

    assert_received {:adapter_telemetry, [:beam_weaver, :cache, :sweep], %{count: 1},
                     %{operation: :sweep, adapter: BeamWeaver.Cache.ETS}}

    assert_received {:adapter_telemetry, [:beam_weaver, :memory, :sweep], %{count: 1},
                     %{operation: :sweep, adapter: BeamWeaver.Memory.ETS}}

    assert_received {:adapter_telemetry, [:beam_weaver, :vector_store, :add_documents], %{count: 1},
                     %{operation: :add_documents, adapter: BeamWeaver.VectorStore.ETS}}

    assert_received {:adapter_telemetry, [:beam_weaver, :vector_store, :similarity_search], %{count: 1},
                     %{
                       operation: :similarity_search,
                       adapter: BeamWeaver.VectorStore.ETS,
                       namespace: "tenant-a",
                       query: "alpha",
                       k: 1
                     }}
  end

  def handle_adapter_telemetry(event, measurements, metadata, parent) do
    send(parent, {:adapter_telemetry, event, measurements, metadata})
  end
end
