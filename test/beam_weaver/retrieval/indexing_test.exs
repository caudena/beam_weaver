defmodule BeamWeaver.IndexingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Indexing
  alias BeamWeaver.Indexing.DocumentIndex, as: ReadWriteIndex
  alias BeamWeaver.Indexing.DocumentIndex.Memory, as: MemoryDocumentIndex
  alias BeamWeaver.Indexing.RecordManager
  alias BeamWeaver.Indexing.RecordManager.ETS, as: RecordETS
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.ETS, as: VectorETS

  defmodule DeleteOnceVectorStore do
    @behaviour BeamWeaver.VectorStore

    alias BeamWeaver.Core.Error
    alias BeamWeaver.Models.FakeEmbeddingModel
    alias BeamWeaver.VectorStore
    alias BeamWeaver.VectorStore.ETS, as: VectorETS

    defstruct [:inner, :delete_flag]

    def new do
      {:ok, flag} = Agent.start_link(fn -> true end)
      %__MODULE__{inner: VectorETS.new(embedding: %FakeEmbeddingModel{}), delete_flag: flag}
    end

    def add_documents(store, documents, opts),
      do: VectorStore.add_documents(store.inner, documents, opts)

    def delete(store, ids, opts) do
      fail? = Agent.get_and_update(store.delete_flag, &{&1, false})

      if fail? do
        {:error, Error.new(:delete_failed_once, "simulated delete failure")}
      else
        VectorStore.delete(store.inner, ids, opts)
      end
    end

    def get_by_ids(store, ids, opts), do: VectorStore.get_by_ids(store.inner, ids, opts)

    def similarity_search(store, query, opts),
      do: VectorStore.similarity_search(store.inner, query, opts)

    def similarity_search_with_score(store, query, opts),
      do: VectorStore.similarity_search_with_score(store.inner, query, opts)

    def similarity_search_by_vector(store, vector, opts),
      do: VectorStore.similarity_search_by_vector(store.inner, vector, opts)

    def max_marginal_relevance_search(store, query, opts),
      do: VectorStore.max_marginal_relevance_search(store.inner, query, opts)
  end

  test "record manager makes indexing idempotent and force update explicit" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()
    docs = [Document.new!("alpha", id: "a", metadata: %{source: "s1"})]

    assert BeamWeaver.Indexing.RecordManager.Backend.impl_for(records)

    assert {:ok, %{added: 1, updated: 0, skipped: 0}} =
             Indexing.index(store, docs, record_manager: records)

    assert {:ok, %{added: 0, updated: 0, skipped: 1}} =
             Indexing.index(store, docs, record_manager: records)

    assert {:ok, %{added: 0, updated: 1, skipped: 0}} =
             Indexing.index(store, docs, record_manager: records, force_update: true)
  end

  test "documents can be copied with deterministic hash ids" do
    # Upstream reference:
    document = Document.new!("Lorem ipsum dolor sit amet", metadata: %{"key" => "value"})

    assert {:ok, hashed} = Indexing.with_hashed_id(document, key_encoder: :sha1)
    assert hashed.id == "fd1dc827-051b-537d-a1fe-1fa043e8b276"
    assert hashed != document
    assert hashed.content == document.content
    assert hashed.metadata == document.metadata

    assert {:ok, same_hash} = Indexing.with_hashed_id(document, key_encoder: "sha1")
    assert same_hash.id == hashed.id

    for algorithm <- [:sha256, :sha512, :blake2b] do
      assert {:ok, different_hash} = Indexing.with_hashed_id(document, key_encoder: algorithm)
      assert different_hash.id != hashed.id
    end
  end

  test "document hash ids accept custom encoders and report bad algorithms" do
    # Upstream reference:
    document = Document.new!("Lorem ipsum dolor sit amet", metadata: %{"key" => "like a duck"})

    assert {:ok, %{id: "quack-like a duck"}} =
             Indexing.with_hashed_id(document,
               key_encoder: fn doc -> "quack-" <> doc.metadata["key"] end
             )

    assert {:error, %{type: :unsupported_hash_algorithm}} =
             Indexing.with_hashed_id(document, key_encoder: :md5)
  end

  test "changed content updates records and vectorstore documents" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    assert {:ok, %{added: 1}} =
             Indexing.index(store, [Document.new!("alpha", id: "doc", metadata: %{source: "s1"})],
               record_manager: records
             )

    assert {:ok, %{updated: 1}} =
             Indexing.index(store, [Document.new!("beta", id: "doc", metadata: %{source: "s1"})],
               record_manager: records
             )

    assert {:ok, [%Document{content: "beta"}]} =
             VectorStore.similarity_search(store, "beta", k: 1)
  end

  test "incremental cleanup removes stale records only in indexed source scope" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    first = [
      Document.new!("alpha", id: "a", metadata: %{source: "s1"}),
      Document.new!("beta", id: "b", metadata: %{source: "s1"}),
      Document.new!("gamma", id: "c", metadata: %{source: "s2"})
    ]

    assert {:ok, %{added: 3}} = Indexing.index(store, first, record_manager: records)

    second = [Document.new!("alpha", id: "a", metadata: %{source: "s1"})]

    assert {:ok, result} =
             Indexing.index(store, second, record_manager: records, cleanup: :incremental)

    assert result.deleted == 1
    assert result.deleted_ids == ["b"]
    assert {:ok, nil} = RecordManager.get(records, "b")
    assert {:ok, [_gamma]} = VectorStore.similarity_search(store, "gamma", k: 1)
  end

  test "incremental cleanup handles same-source deletion without touching other sources" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    first = [
      Document.new!("This is a test document.", id: "a", metadata: %{source: "1"}),
      Document.new!("This is another document.", id: "b", metadata: %{source: "1"}),
      Document.new!("Other source document.", id: "c", metadata: %{source: "2"})
    ]

    assert {:ok, %{added: 3}} = Indexing.index(store, first, record_manager: records)

    second = [
      Document.new!("This is another document.", id: "b", metadata: %{source: "1"})
    ]

    assert {:ok, result} =
             Indexing.index(store, second, record_manager: records, cleanup: :incremental)

    assert result.deleted == 1
    assert result.deleted_ids == ["a"]
    assert {:ok, nil} = RecordManager.get(records, "a")

    assert {:ok, [%Document{content: "Other source document."}]} =
             VectorStore.similarity_search(store, "Other source", k: 1)
  end

  test "source_id_key and explicit scoped cleanup scope cleanup to current document sources" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    first = [
      Document.new!("source one old", id: "a", metadata: %{source: "1"}),
      Document.new!("source one keep", id: "b", metadata: %{source: "1"}),
      Document.new!("source two keep", id: "c", metadata: %{source: "2"})
    ]

    assert {:ok, %{added: 3}} =
             Indexing.index(store, first,
               record_manager: records,
               cleanup: {:full, ["1"]},
               source_id_key: "source"
             )

    second = [Document.new!("source one keep", id: "b", metadata: %{source: "1"})]

    assert {:ok, result} =
             Indexing.index(store, second,
               record_manager: records,
               cleanup: {:full, ["1"]},
               source_id_key: :source
             )

    assert result.deleted == 1
    assert result.deleted_ids == ["a"]

    assert {:ok, [%Document{content: "source two keep"}]} =
             VectorStore.similarity_search(store, "source two", k: 1)
  end

  test "source_id_key reports missing or nil source metadata as tagged errors" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    assert {:error, %{type: :missing_source_id}} =
             Indexing.index(store, [Document.new!("missing source")],
               record_manager: records,
               cleanup: :incremental,
               source_id_key: :source
             )

    assert {:error, %{type: :missing_source_id}} =
             Indexing.index(store, [Document.new!("nil source", metadata: %{source: nil})],
               record_manager: records,
               cleanup: "incremental",
               source_id_key: "source"
             )
  end

  test "full cleanup with force removes stale records across the namespace" do
    # Adapts upstream full cleanup behavior to BeamWeaver's explicit force requirement.
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    assert {:ok, %{added: 2}} =
             Indexing.index(
               store,
               [
                 Document.new!("This is a test document."),
                 Document.new!("This is another document.")
               ],
               record_manager: records
             )

    assert {:ok, result} =
             Indexing.index(
               store,
               [Document.new!("mutated document 1"), Document.new!("This is another document.")],
               record_manager: records,
               cleanup: {:full, nil},
               force?: true
             )

    assert result.added == 1
    assert result.skipped == 1
    assert result.deleted == 1
  end

  test "full cleanup recovers on the next run after vector deletion fails" do
    store = DeleteOnceVectorStore.new()
    records = RecordETS.new()

    on_exit(fn ->
      if Process.alive?(store.delete_flag), do: Agent.stop(store.delete_flag)
    end)

    first = [
      Document.new!("old content", id: "old"),
      Document.new!("kept content", id: "keep")
    ]

    assert {:ok, %{added: 2}} = Indexing.index(store, first, record_manager: records)

    second = [
      Document.new!("new content", id: "new"),
      Document.new!("kept content", id: "keep")
    ]

    assert {:error, %{type: :delete_failed_once}} =
             Indexing.index(store, second,
               record_manager: records,
               cleanup: :full,
               force?: true
             )

    assert {:ok, %BeamWeaver.Indexing.Record{id: "old"}} = RecordManager.get(records, "old")
    assert {:ok, [%Document{id: "old"}]} = VectorStore.get_by_ids(store, ["old"])

    assert {:ok, result} =
             Indexing.index(store, second,
               record_manager: records,
               cleanup: :full,
               force?: true
             )

    assert result.skipped == 2
    assert result.deleted == 1
    assert result.deleted_ids == ["old"]
    assert {:ok, nil} = RecordManager.get(records, "old")
    assert {:ok, []} = VectorStore.get_by_ids(store, ["old"])
  end

  test "full cleanup aliases preserve explicit force requirement" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    assert {:ok, %{added: 1}} =
             Indexing.index(store, [Document.new!("alpha", id: "a")], record_manager: records)

    assert {:error, %{type: :unsafe_index_cleanup}} =
             Indexing.index(store, [], record_manager: records, cleanup: "full")

    assert {:ok, %{deleted: 1}} =
             Indexing.index(store, [],
               record_manager: records,
               cleanup: :full,
               force?: true
             )
  end

  test "empty full cleanup is safe and reports zero work" do
    # Translates upstream test_indexing_with_no_docs.
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    assert {:ok, %{added: 0, updated: 0, skipped: 0, deleted: 0}} =
             Indexing.index(store, [],
               record_manager: records,
               cleanup: {:full, nil},
               force?: true
             )
  end

  test "within-batch duplicate documents are counted as skipped" do
    # Translates upstream test_deduplication and test_within_batch_deduplication_counting.
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    docs = [
      Document.new!("This is a test document.", metadata: %{source: "1"}),
      Document.new!("This is a test document.", metadata: %{source: "1"}),
      Document.new!("Document B", metadata: %{source: "2"})
    ]

    assert {:ok, result} =
             Indexing.index(store, docs,
               record_manager: records,
               cleanup: {:full, nil},
               force?: true
             )

    assert result.added == 2
    assert result.skipped == 1
    assert result.deleted == 0
  end

  test "small batch sizes preserve indexing and cleanup semantics" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    first = [
      Document.new!("alpha", id: "a", metadata: %{source: "s"}),
      Document.new!("beta", id: "b", metadata: %{source: "s"}),
      Document.new!("gamma", id: "c", metadata: %{source: "s"})
    ]

    assert {:ok, %{added: 3, skipped: 0}} =
             Indexing.index(store, first,
               record_manager: records,
               cleanup: :incremental,
               batch_size: 1
             )

    assert {:ok, result} =
             Indexing.index(store, [Document.new!("alpha", id: "a", metadata: %{source: "s"})],
               record_manager: records,
               cleanup: :incremental,
               batch_size: 1
             )

    assert result.skipped == 1
    assert result.deleted == 2
    assert Enum.sort(result.deleted_ids) == ["b", "c"]
  end

  test "full cleanup requires explicit scope unless force is set" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    assert {:ok, %{added: 1}} =
             Indexing.index(store, [Document.new!("alpha", id: "a", metadata: %{source: "s1"})],
               record_manager: records
             )

    assert {:error, %{type: :unsafe_index_cleanup}} =
             Indexing.index(store, [], record_manager: records, cleanup: {:full, nil})

    assert {:ok, %{deleted: 1}} =
             Indexing.index(store, [],
               record_manager: records,
               cleanup: {:full, nil},
               force?: true
             )
  end

  test "async indexing uses BeamWeaver async handles" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    task =
      Indexing.async_index(store, [Document.new!("alpha", id: "a")], record_manager: records)

    assert {:ok, %{added: 1}} = Async.await(task)
  end

  test "record manager facade covers standard update exists list delete and async helpers" do
    # Upstream reference:
    records = RecordETS.new(namespace: :records)

    start = RecordManager.get_time(records)
    assert :ok = RecordManager.update(records, ["a"], group_ids: ["s1"])
    Process.sleep(1)
    assert :ok = RecordManager.update(records, ["b"], group_ids: ["s2"])
    assert [true, false, true] = RecordManager.exists(records, ["a", "missing", "b"])

    assert ["a"] = RecordManager.list_keys(records, group_ids: ["s1"])
    assert ["a"] = RecordManager.list_keys(records, after: start, limit: 1)

    assert {:error, %{type: :invalid_record_manager_update}} =
             RecordManager.update(records, ["a"], group_ids: ["s1", "extra"])

    assert {:error, %{type: :invalid_record_manager_time}} =
             RecordManager.update(records, ["future"], time_at_least: RecordManager.get_time(records) + 60)

    assert :ok = RecordManager.async_update(records, ["c"], group_ids: ["s3"]) |> Async.await()
    assert [true] = RecordManager.async_exists(records, ["c"]) |> Async.await()
    assert ["c"] = RecordManager.async_list_keys(records, group_ids: ["s3"]) |> Async.await()

    assert :ok = RecordManager.async_delete_keys(records, ["a", "c"]) |> Async.await()
    assert [false, true, false] = RecordManager.exists(records, ["a", "b", "c"])
  end

  test "memory document index supports standard upsert get delete retrieve and async helpers" do
    index = MemoryDocumentIndex.new(top_k: 1)

    assert {:ok, %{succeeded: ["foo-id", generated], failed: []}} =
             ReadWriteIndex.upsert(index, [
               Document.new!("foo foo", id: "foo-id", metadata: %{kind: "known"}),
               Document.new!("bar", metadata: %{kind: "generated"})
             ])

    assert is_binary(generated)

    assert {:ok,
            [
              %Document{id: "foo-id", content: "foo foo"},
              %Document{id: ^generated, content: "bar"}
            ]} = ReadWriteIndex.get(index, ["foo-id", generated, "missing"])

    assert {:ok, %{succeeded: ["foo-id"], failed: []}} =
             ReadWriteIndex.upsert(index, [Document.new!("foo2", id: "foo-id")])

    assert {:ok, [%Document{id: "foo-id", content: "foo2"}]} =
             ReadWriteIndex.get(index, ["foo-id"])

    assert {:ok, [%Document{id: "foo-id"}]} = BeamWeaver.Retriever.retrieve(index, "foo")

    assert {:ok, %{succeeded: ["foo-id"], num_deleted: 1, num_failed: 0, failed: []}} =
             ReadWriteIndex.delete(index, ["missing", "foo-id"])

    assert {:ok, []} = ReadWriteIndex.get(index, ["foo-id"])
    assert {:error, %{type: :missing_document_ids}} = ReadWriteIndex.delete(index)

    assert {:ok, %{succeeded: ["async-id"]}} =
             ReadWriteIndex.async_upsert(index, [Document.new!("async", id: "async-id")])
             |> Async.await()

    assert {:ok, [%Document{id: "async-id"}]} =
             ReadWriteIndex.async_get(index, ["async-id"]) |> Async.await()

    assert {:ok, %{succeeded: ["async-id"]}} =
             ReadWriteIndex.async_delete(index, ["async-id"]) |> Async.await()
  end

  test "memory document index retrieves ranked documents through sync and async retriever facade" do
    # Upstream reference:
    index = MemoryDocumentIndex.new(top_k: 2)

    documents = [
      Document.new!("hello world", id: "1"),
      Document.new!("goodbye cat", id: "2")
    ]

    assert {:ok, %{succeeded: ["1", "2"]}} = ReadWriteIndex.upsert(index, documents)

    assert {:ok, [%Document{id: "1"}, %Document{id: "2"}]} =
             BeamWeaver.Retriever.retrieve(index, "hello")

    assert {:ok, [%Document{id: "2"}, %Document{id: "1"}]} =
             BeamWeaver.Retriever.async_retrieve(index, "cat") |> Async.await()
  end
end
