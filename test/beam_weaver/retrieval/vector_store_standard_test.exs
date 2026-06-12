defmodule BeamWeaver.VectorStoreStandardTest do
  use ExUnit.Case, async: true

  # Native coverage for:

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.ETS

  defp new_store, do: ETS.new(embedding: %FakeEmbeddingModel{dimensions: 6})

  test "fresh stores are empty before and after independent tests" do
    assert {:ok, []} = VectorStore.similarity_search(new_store(), "foo", k: 1)

    assert {:ok, []} =
             VectorStore.async_similarity_search(new_store(), "foo", k: 1) |> Async.await()
  end

  test "add_documents returns generated ids, searches by similarity, and does not mutate input structs" do
    store = new_store()

    original_documents = [
      Document.new!("foo", metadata: %{id: 1}),
      Document.new!("bar", metadata: %{id: 2})
    ]

    assert {:ok, ids} = VectorStore.add_documents(store, original_documents)

    assert {:ok,
            [
              %Document{content: "bar", metadata: %{id: 2}, id: id2},
              %Document{content: "foo", metadata: %{id: 1}, id: id1}
            ]} = VectorStore.similarity_search(store, "bar", k: 2)

    assert [id1, id2] == ids
    assert Enum.all?(ids, &is_binary/1)

    assert original_documents == [
             Document.new!("foo", metadata: %{id: 1}),
             Document.new!("bar", metadata: %{id: 2})
           ]
  end

  test "explicit ids drive delete, missing delete, and idempotent upsert" do
    store = new_store()

    documents = [
      Document.new!("foo", metadata: %{id: 1}),
      Document.new!("bar", metadata: %{id: 2})
    ]

    assert {:ok, ["1", "2"]} =
             VectorStore.add_documents(store, documents, ids: ["1", "2"])

    assert :ok = VectorStore.delete(store, ["1"])

    assert {:ok, [%Document{content: "bar", id: "2"}]} =
             VectorStore.similarity_search(store, "foo", k: 1)

    assert :ok = VectorStore.delete(store, ["missing"])
    assert :ok = VectorStore.delete(store, ["missing", "still-missing"])

    assert {:ok, ["1", "2"]} =
             VectorStore.add_documents(store, Enum.take(documents, 2), ids: ["1", "2"])

    assert {:ok, ["1", "2"]} =
             VectorStore.add_documents(store, Enum.take(documents, 2), ids: ["1", "2"])

    assert {:ok,
            [
              %Document{content: "bar", id: "2"},
              %Document{content: "foo", id: "1"}
            ]} = VectorStore.similarity_search(store, "bar", k: 2)
  end

  test "bulk delete removes several explicit ids at once" do
    store = new_store()

    assert {:ok, ["1", "2", "3"]} =
             VectorStore.add_documents(
               store,
               [
                 Document.new!("foo", metadata: %{id: 1}),
                 Document.new!("bar", metadata: %{id: 2}),
                 Document.new!("baz", metadata: %{id: 3})
               ],
               ids: ["1", "2", "3"]
             )

    assert :ok = VectorStore.delete(store, ["1", "2"])

    assert {:ok, [%Document{content: "baz", id: "3"}]} =
             VectorStore.similarity_search(store, "foo", k: 1)
  end

  test "add_documents overwrites existing ids without duplicating rows" do
    store = new_store()

    assert {:ok, ["1", "2"]} =
             VectorStore.add_documents(
               store,
               [
                 Document.new!("foo", metadata: %{id: 1}),
                 Document.new!("bar", metadata: %{id: 2})
               ],
               ids: ["1", "2"]
             )

    assert {:ok, ["1"]} =
             VectorStore.add_documents(
               store,
               [Document.new!("new foo", metadata: %{id: 1, some_other_field: "foo"})],
               ids: ["1"]
             )

    assert {:ok,
            [
              %Document{id: "1", content: "new foo", metadata: %{id: 1, some_other_field: "foo"}},
              %Document{id: "2", content: "bar", metadata: %{id: 2}}
            ]} = VectorStore.similarity_search(store, "new foo", k: 2)
  end

  test "get_by_ids returns existing documents in requested order and skips missing ids" do
    store = new_store()

    documents = [
      Document.new!("foo", metadata: %{id: 1}),
      Document.new!("bar", metadata: %{id: 2})
    ]

    assert {:ok, ["1", "2"]} = VectorStore.add_documents(store, documents, ids: ["1", "2"])

    assert {:ok,
            [
              %Document{id: "2", content: "bar", metadata: %{id: 2}},
              %Document{id: "1", content: "foo", metadata: %{id: 1}}
            ]} = VectorStore.get_by_ids(store, ["2", "missing", "1"])

    assert {:ok, []} = VectorStore.get_by_ids(store, ["missing-1", "missing-2"])
  end

  test "document ids are preserved when present and generated for missing ids" do
    store = new_store()

    documents = [
      Document.new!("foo", id: "foo", metadata: %{id: 1}),
      Document.new!("bar", metadata: %{id: 2})
    ]

    assert {:ok, ["foo", generated]} = VectorStore.add_documents(store, documents)
    assert is_binary(generated)

    assert {:ok,
            [
              %Document{id: "foo", content: "foo", metadata: %{id: 1}},
              %Document{id: ^generated, content: "bar", metadata: %{id: 2}}
            ]} = VectorStore.get_by_ids(store, ["foo", generated])
  end

  test "Task-backed async vectorstore operations mirror sync semantics" do
    store = new_store()

    documents = [
      Document.new!("foo", metadata: %{id: 1}),
      Document.new!("bar", metadata: %{id: 2})
    ]

    assert {:ok, ids} = VectorStore.async_add_documents(store, documents) |> Async.await()

    assert {:ok, [%Document{content: "bar"}, %Document{content: "foo"}]} =
             VectorStore.async_similarity_search(store, "bar", k: 2) |> Async.await()

    assert documents == [
             Document.new!("foo", metadata: %{id: 1}),
             Document.new!("bar", metadata: %{id: 2})
           ]

    assert :ok = VectorStore.async_delete(store, [hd(ids)]) |> Async.await()

    assert {:ok, [%Document{content: "bar"}]} =
             VectorStore.async_similarity_search(store, "foo", k: 1) |> Async.await()

    assert {:ok, []} =
             VectorStore.async_get_by_ids(store, ["missing-1", "missing-2"]) |> Async.await()
  end

  test "Task-backed async upsert and get_by_ids cover mixed document ids" do
    store = new_store()

    assert {:ok, ["1", "2"]} =
             VectorStore.async_add_documents(
               store,
               [
                 Document.new!("foo", metadata: %{id: 1}),
                 Document.new!("bar", metadata: %{id: 2})
               ],
               ids: ["1", "2"]
             )
             |> Async.await()

    assert {:ok, ["1"]} =
             VectorStore.async_add_documents(
               store,
               [Document.new!("new foo", metadata: %{id: 1, some_other_field: "foo"})],
               ids: ["1"]
             )
             |> Async.await()

    assert {:ok,
            [
              %Document{id: "1", content: "new foo"},
              %Document{id: "2", content: "bar"}
            ]} = VectorStore.async_get_by_ids(store, ["1", "2"]) |> Async.await()

    mixed_store = new_store()

    assert {:ok, ["foo", generated]} =
             VectorStore.async_add_documents(
               mixed_store,
               [
                 Document.new!("foo", id: "foo", metadata: %{id: 1}),
                 Document.new!("bar", metadata: %{id: 2})
               ]
             )
             |> Async.await()

    assert is_binary(generated)

    assert {:ok, [%Document{id: "foo"}, %Document{id: ^generated}]} =
             VectorStore.async_get_by_ids(mixed_store, ["foo", generated]) |> Async.await()
  end

  test "add_texts accepts a single string and metadata lists" do
    store = new_store()

    assert {:ok, ["single"]} =
             VectorStore.add_texts(store, "single text",
               ids: ["single"],
               metadata: %{kind: "one"}
             )

    assert {:ok, [%Document{id: "single", content: "single text", metadata: %{kind: "one"}}]} =
             VectorStore.get_by_ids(store, ["single"])

    assert {:ok, ["a", "b"]} =
             VectorStore.add_texts(store, ["alpha", "beta"],
               ids: ["a", "b"],
               metadatas: [%{kind: "letter"}, %{kind: "letter"}]
             )

    assert {:ok, [%Document{id: "a"}, %Document{id: "b"}]} =
             VectorStore.get_by_ids(store, ["a", "b"])
  end

  test "facade builds populated vector stores from documents and texts" do
    assert {:ok, store} =
             VectorStore.from_documents(
               ETS,
               [Document.new!("alpha", id: "doc-a", metadata: %{source: "doc"})],
               embedding: %FakeEmbeddingModel{dimensions: 6}
             )

    assert {:ok, [%Document{id: "doc-a", content: "alpha"}]} =
             VectorStore.get_by_ids(store, ["doc-a"])

    assert {:ok, %FakeEmbeddingModel{dimensions: 6}} = VectorStore.embedding(store)

    assert {:ok, text_store} =
             VectorStore.from_texts(ETS, ["beta", "gamma"],
               ids: ["text-b", "text-g"],
               metadatas: [%{rank: 1}, %{rank: 2}],
               embedding: %FakeEmbeddingModel{dimensions: 6}
             )

    assert {:ok, [%Document{metadata: %{rank: 1}}, %Document{metadata: %{rank: 2}}]} =
             VectorStore.get_by_ids(text_store, ["text-b", "text-g"])

    assert {:ok, async_store} =
             VectorStore.async_from_texts(ETS, ["delta"],
               ids: ["text-d"],
               embedding: %FakeEmbeddingModel{dimensions: 6}
             )
             |> Async.await()

    assert {:ok, [%Document{id: "text-d"}]} = VectorStore.get_by_ids(async_store, ["text-d"])
  end

  test "ETS store filters can use metadata maps or full document predicates" do
    store = new_store()

    documents = [
      Document.new!("first document", id: "doc_1", metadata: %{group: "odd"}),
      Document.new!("second document", id: "doc_2", metadata: %{group: "even"}),
      Document.new!("third document", id: "doc_3", metadata: %{group: "odd"})
    ]

    assert {:ok, ["doc_1", "doc_2", "doc_3"]} = VectorStore.add_documents(store, documents)

    assert {:ok, [%Document{id: "doc_2"}]} =
             VectorStore.similarity_search(store, "document", k: 3, filter: %{group: "even"})

    assert {:ok, results} =
             VectorStore.similarity_search(store, "document",
               k: 3,
               filter: fn document -> document.id in ["doc_1", "doc_3"] end
             )

    assert MapSet.new(Enum.map(results, & &1.id)) == MapSet.new(["doc_1", "doc_3"])
  end

  test "MMR supports Python lambda_mult naming through native options" do
    store = new_store()

    assert {:ok, _ids} =
             VectorStore.add_texts(store, ["foo", "foo", "fou", "foy"], ids: ["1", "2", "3", "4"])

    assert {:ok, results} =
             VectorStore.max_marginal_relevance_search(store, "foo",
               k: 10,
               fetch_k: 10,
               lambda_mult: 0.1
             )

    assert length(results) == 4
    assert hd(results).content == "foo"
  end

  test "ETS store dumps and loads documents and vectors explicitly" do
    store = new_store()

    assert {:ok, ["1", "2", "3"]} =
             VectorStore.add_texts(store, ["foo", "bar", "baz"], ids: ["1", "2", "3"])

    assert {:ok, before_dump} = VectorStore.similarity_search(store, "foo", k: 2)

    path =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_vector_store_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert :ok = ETS.dump(store, path)
    assert {:ok, loaded} = ETS.load(path, embedding: %FakeEmbeddingModel{dimensions: 6})
    assert {:ok, after_load} = VectorStore.similarity_search(loaded, "foo", k: 2)

    assert Enum.map(before_dump, &{&1.id, &1.content}) ==
             Enum.map(after_load, &{&1.id, &1.content})
  end
end
