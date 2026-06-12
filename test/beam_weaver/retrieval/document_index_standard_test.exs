defmodule BeamWeaver.DocumentIndexStandardTest do
  use ExUnit.Case, async: true

  # Native coverage for:

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Indexing.DocumentIndex
  alias BeamWeaver.Indexing.DocumentIndex.Memory

  defp new_index, do: Memory.new()

  test "upsert has no separate ids API and generated ids round-trip documents" do
    refute function_exported?(DocumentIndex, :upsert, 4)

    index = new_index()
    assert BeamWeaver.Indexing.DocumentIndex.Backend.impl_for(index)

    assert {:ok, %{succeeded: ids, failed: []}} =
             DocumentIndex.upsert(index, [
               Document.new!("foo", metadata: %{id: 1}),
               Document.new!("bar", metadata: %{id: 2})
             ])

    assert Enum.all?(ids, &is_binary/1)

    assert {:ok, documents} = DocumentIndex.get(index, Enum.sort(ids))

    assert documents
           |> Enum.sort_by(& &1.content)
           |> Enum.map(&{&1.content, &1.metadata}) == [
             {"bar", %{id: 2}},
             {"foo", %{id: 1}}
           ]
  end

  test "upsert preserves explicit document ids and overwrites existing content" do
    index = new_index()
    explicit_id = "00000000-0000-0000-0000-000000000007"

    assert {:ok, %{succeeded: [^explicit_id, generated], failed: []}} =
             DocumentIndex.upsert(index, [
               Document.new!("foo", id: explicit_id, metadata: %{id: 1}),
               Document.new!("bar", metadata: %{id: 2})
             ])

    assert is_binary(generated)

    assert {:ok,
            [
              %Document{id: ^explicit_id, content: "foo", metadata: %{id: 1}},
              %Document{id: ^generated, content: "bar", metadata: %{id: 2}}
            ]} = DocumentIndex.get(index, [explicit_id, generated])

    assert {:ok, %{succeeded: [^explicit_id], failed: []}} =
             DocumentIndex.upsert(index, [
               Document.new!("foo2", id: explicit_id, metadata: %{meow: 2})
             ])

    assert {:ok, [%Document{id: ^explicit_id, content: "foo2", metadata: %{meow: 2}}]} =
             DocumentIndex.get(index, [explicit_id])
  end

  test "delete missing, mixed, and bulk ids reports no missing-id failures" do
    index = new_index()

    assert {:ok, []} = DocumentIndex.get(index, ["1"])

    assert {:ok, %{succeeded: [], failed: [], num_deleted: 0, num_failed: 0}} =
             DocumentIndex.delete(index, ["1"])

    assert {:ok, %{succeeded: ["1", "2", "3"], failed: []}} =
             DocumentIndex.upsert(index, [
               Document.new!("foo", id: "1", metadata: %{id: 1}),
               Document.new!("bar", id: "2", metadata: %{id: 2}),
               Document.new!("baz", id: "3", metadata: %{id: 3})
             ])

    assert {:ok, %{succeeded: ["1", "2"], failed: [], num_deleted: 2, num_failed: 0}} =
             DocumentIndex.delete(index, ["missing", "1", "2"])

    assert {:ok, [%Document{id: "3", content: "baz", metadata: %{id: 3}}]} =
             DocumentIndex.get(index, ["1", "2", "3"])

    assert {:ok, %{succeeded: [], failed: [], num_deleted: 0, num_failed: 0}} =
             DocumentIndex.delete(index, ["missing", "still-missing"])
  end

  test "delete without ids returns a tagged error instead of raising" do
    assert {:error, %{type: :missing_document_ids}} = DocumentIndex.delete(new_index())
  end

  test "get skips missing ids and preserves requested order for existing ids" do
    index = new_index()

    assert {:ok, %{succeeded: ["1", "2"], failed: []}} =
             DocumentIndex.upsert(index, [
               Document.new!("foo", id: "1", metadata: %{id: 1}),
               Document.new!("bar", id: "2", metadata: %{id: 2})
             ])

    assert {:ok,
            [
              %Document{id: "2", content: "bar"},
              %Document{id: "1", content: "foo"}
            ]} = DocumentIndex.get(index, ["2", "missing", "1"])

    assert {:ok, []} = DocumentIndex.get(index, ["missing-1", "missing-2"])
  end

  test "Task-backed async read/write index operations mirror sync semantics" do
    index = new_index()
    explicit_id = "00000000-0000-0000-0000-000000000007"

    assert {:ok, %{succeeded: [^explicit_id, generated], failed: []}} =
             DocumentIndex.async_upsert(index, [
               Document.new!("foo", id: explicit_id, metadata: %{id: 1}),
               Document.new!("bar", metadata: %{id: 2})
             ])
             |> Async.await()

    assert is_binary(generated)

    assert {:ok,
            [
              %Document{id: ^explicit_id, content: "foo"},
              %Document{id: ^generated, content: "bar"}
            ]} =
             DocumentIndex.async_get(index, [explicit_id, generated, "missing"])
             |> Async.await()

    assert {:ok, %{succeeded: [^explicit_id], failed: []}} =
             DocumentIndex.async_upsert(index, [
               Document.new!("foo2", id: explicit_id, metadata: %{meow: 2})
             ])
             |> Async.await()

    assert {:ok, [%Document{id: ^explicit_id, content: "foo2", metadata: %{meow: 2}}]} =
             DocumentIndex.async_get(index, [explicit_id])
             |> Async.await()

    assert {:ok, %{succeeded: [^explicit_id], failed: [], num_deleted: 1, num_failed: 0}} =
             DocumentIndex.async_delete(index, ["missing", explicit_id])
             |> Async.await()

    assert {:error, %{type: :missing_document_ids}} =
             DocumentIndex.async_delete(index) |> Async.await()
  end
end
