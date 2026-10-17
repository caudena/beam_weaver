defmodule BeamWeaver.IndexingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Indexing
  alias BeamWeaver.Indexing.Record
  alias BeamWeaver.Indexing.RecordManager
  alias BeamWeaver.Indexing.RecordManager.ETS, as: RecordETS
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.TextSplitter
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

  # Rejects writes of documents from the sources in `reject`, an Agent.
  defmodule RejectingVectorStore do
    @behaviour BeamWeaver.VectorStore

    alias BeamWeaver.Core.Error
    alias BeamWeaver.Models.FakeEmbeddingModel
    alias BeamWeaver.VectorStore
    alias BeamWeaver.VectorStore.ETS, as: VectorETS

    defstruct [:inner, :reject]

    def new do
      {:ok, reject} = Agent.start_link(fn -> [] end)
      %__MODULE__{inner: VectorETS.new(embedding: %FakeEmbeddingModel{}), reject: reject}
    end

    def add_documents(store, documents, opts) do
      rejected = Agent.get(store.reject, & &1)

      if Enum.any?(documents, &(&1.metadata.source in rejected)),
        do: {:error, Error.new(:write_rejected, "simulated write failure")},
        else: VectorStore.add_documents(store.inner, documents, opts)
    end

    def delete(store, ids, opts), do: VectorStore.delete(store.inner, ids, opts)
    def get_by_ids(store, ids, opts), do: VectorStore.get_by_ids(store.inner, ids, opts)
    def similarity_search(store, query, opts), do: VectorStore.similarity_search(store.inner, query, opts)

    def similarity_search_with_score(store, query, opts),
      do: VectorStore.similarity_search_with_score(store.inner, query, opts)

    def similarity_search_by_vector(store, vector, opts),
      do: VectorStore.similarity_search_by_vector(store.inner, vector, opts)

    def max_marginal_relevance_search(store, query, opts),
      do: VectorStore.max_marginal_relevance_search(store.inner, query, opts)
  end

  test "cleanup keeps the old chunks of a source whose new chunks failed to write" do
    first = [
      Document.new!("refunds take 5 days", id: "refunds-v1", metadata: %{source: "refunds.md"}),
      Document.new!("shipping takes 3 days", id: "shipping-v1", metadata: %{source: "shipping.md"})
    ]

    second = [
      Document.new!("refunds take 3 days", id: "refunds-v2", metadata: %{source: "refunds.md"}),
      Document.new!("shipping takes 2 days", id: "shipping-v2", metadata: %{source: "shipping.md"})
    ]

    for cleanup <- [:incremental, {:full, ["refunds.md", "shipping.md"]}] do
      store = RejectingVectorStore.new()
      records = RecordETS.new()
      opts = [record_manager: records, cleanup: cleanup, batch_size: 1]

      assert {:ok, %{added: 2}} = Indexing.index(store, first, opts)

      Agent.update(store.reject, fn _ -> ["refunds.md"] end)

      assert {:ok, result} = Indexing.index(store, second, opts)

      assert %{added: 1, failed: 1, failed_ids: ["refunds-v2"], errors: [%{type: :write_rejected}]} = result
      assert result.deleted_ids == ["shipping-v1"]

      # The refunds article stays searchable in its old version.
      assert {:ok, [%Document{content: "refunds take 5 days"}]} = VectorStore.get_by_ids(store, ["refunds-v1"])
      assert {:ok, %BeamWeaver.Indexing.Record{}} = RecordManager.get(records, "refunds-v1")

      # Once the write succeeds, the next run cleans up the old version.
      Agent.update(store.reject, fn _ -> [] end)

      assert {:ok, %{added: 1, skipped: 1, deleted_ids: ["refunds-v1"]}} = Indexing.index(store, second, opts)
    end
  end

  test "full cleanup with force keeps sources whose new chunks failed to write" do
    store = RejectingVectorStore.new()
    records = RecordETS.new()

    first = [
      Document.new!("refunds take 5 days", id: "refunds-v1", metadata: %{source: "refunds.md"}),
      Document.new!("old faq", id: "faq-v1", metadata: %{source: "faq.md"})
    ]

    assert {:ok, %{added: 2}} = Indexing.index(store, first, record_manager: records)

    Agent.update(store.reject, fn _ -> ["refunds.md"] end)
    second = [Document.new!("refunds take 3 days", id: "refunds-v2", metadata: %{source: "refunds.md"})]

    assert {:ok, %{failed: 1, deleted_ids: ["faq-v1"]}} =
             Indexing.index(store, second, record_manager: records, cleanup: :full, force?: true)

    assert {:ok, [%Document{id: "refunds-v1"}]} = VectorStore.get_by_ids(store, ["refunds-v1"])
  end

  test "record manager makes indexing idempotent and force update explicit" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()
    docs = [Document.new!("alpha", id: "a", metadata: %{source: "s1"})]

    assert BeamWeaver.Indexing.RecordManager.record_manager?(records)

    assert {:ok, %{added: 1, updated: 0, skipped: 0}} =
             Indexing.index(store, docs, record_manager: records)

    assert {:ok, %{added: 0, updated: 0, skipped: 1}} =
             Indexing.index(store, docs, record_manager: records)

    assert {:ok, %{added: 0, updated: 1, skipped: 0}} =
             Indexing.index(store, docs, record_manager: records, force_update: true)
  end

  test "documents can be copied with deterministic hash ids" do
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

  test "incremental cleanup deletes the chunks a shorter document no longer has" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()
    opts = [record_manager: records, cleanup: :incremental]
    splitter = TextSplitter.recursive_character(chunk_size: 25, chunk_overlap: 0)

    refunds = Document.new!("Refunds take 5 days.\nStore credit is instant.\nGift cards never expire.", id: "refunds")
    shipping = Document.new!("Parcels ship in 2 days.", id: "shipping")

    {:ok, chunks} = TextSplitter.split_documents(splitter, [refunds, shipping])
    assert {:ok, %{added: 4}} = Indexing.index(store, chunks, opts)

    {:ok, chunks} = TextSplitter.split_documents(splitter, [Document.new!("Refunds take 3 days.", id: "refunds")])
    assert {:ok, result} = Indexing.index(store, chunks, opts)

    assert {result.updated, result.deleted, Enum.sort(result.deleted_ids)} == {1, 2, ["refunds:1", "refunds:2"]}

    assert {:ok, [%Document{id: "refunds:0", content: "Refunds take 3 days."}]} =
             VectorStore.get_by_ids(store, ["refunds:0", "refunds:1", "refunds:2"])

    assert {:ok, [%Document{id: "shipping:0"}]} = VectorStore.get_by_ids(store, ["shipping:0"])
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
      # The agent is linked to the test process and may already be gone.
      try do
        Agent.stop(store.delete_flag)
      catch
        :exit, _reason -> :ok
      end
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

  test "record manager facade covers standard update exists list and delete" do
    records = RecordETS.new(namespace: :records)

    assert :ok = RecordManager.update(records, ["a"], group_ids: ["s1"])
    assert :ok = RecordManager.update(records, ["b"], group_ids: ["s2"])
    assert [true, false, true] = RecordManager.exists(records, ["a", "missing", "b"])

    assert ["a"] = RecordManager.list_keys(records, group_ids: ["s1"])

    assert {:error, %{type: :invalid_record_manager_update}} =
             RecordManager.update(records, ["a"], group_ids: ["s1", "extra"])

    assert {:error, %{type: :invalid_record_manager_time}} =
             RecordManager.update(records, ["future"], time_at_least: RecordManager.get_time(records) + 60)

    assert :ok = RecordManager.update(records, ["c"], group_ids: ["s3"])
    assert [true] = RecordManager.exists(records, ["c"])
    assert ["c"] = RecordManager.list_keys(records, group_ids: ["s3"])

    assert :ok = RecordManager.delete_keys(records, ["a", "c"])
    assert [false, true, false] = RecordManager.exists(records, ["a", "b", "c"])
  end

  test "record manager key listing has a deterministic id tie-break" do
    records = RecordETS.new(namespace: :records)
    updated_at = DateTime.utc_now()

    assert :ok =
             RecordManager.put(records, %Record{
               id: "b",
               source_id: nil,
               hash: "b",
               updated_at: updated_at
             })

    assert :ok =
             RecordManager.put(records, %Record{
               id: "a",
               source_id: nil,
               hash: "a",
               updated_at: updated_at
             })

    assert ["a", "b"] = RecordManager.list_keys(records)

    after_time = DateTime.to_unix(updated_at, :microsecond) / 1_000_000 - 1
    assert ["a"] = RecordManager.list_keys(records, after: after_time, limit: 1)
  end
end
