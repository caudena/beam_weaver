defmodule BeamWeaver.VectorStore.ETSTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.ETS

  defp new_store, do: ETS.new(embedding: %FakeEmbeddingModel{dimensions: 6})

  test "get_by_ids normalizes non-string ids to match stored stringified keys" do
    store = new_store()

    assert {:ok, ["123", "foo"]} =
             VectorStore.add_documents(
               store,
               [
                 Document.new!("first", metadata: %{id: 1}),
                 Document.new!("second", metadata: %{id: 2})
               ],
               ids: [123, :foo]
             )

    assert {:ok, [%Document{id: "123"}, %Document{id: "foo"}]} =
             VectorStore.get_by_ids(store, [123, :foo])
  end

  test "delete normalizes non-string ids to match stored stringified keys" do
    store = new_store()

    assert {:ok, ["123", "foo"]} =
             VectorStore.add_documents(
               store,
               [
                 Document.new!("first", metadata: %{id: 1}),
                 Document.new!("second", metadata: %{id: 2})
               ],
               ids: [123, :foo]
             )

    assert :ok = VectorStore.delete(store, [123])

    assert {:ok, []} = VectorStore.get_by_ids(store, [123])
    assert {:ok, [%Document{id: "foo"}]} = VectorStore.get_by_ids(store, [:foo])
  end
end
