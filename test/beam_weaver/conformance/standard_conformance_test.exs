defmodule BeamWeaver.TestSupport.Conformance.StandardConformanceFixtures do
  def cache, do: BeamWeaver.Cache.ETS.new(visibility: :private)

  def chat_history_session do
    BeamWeaver.Core.ChatHistory.ETS.new()
    |> BeamWeaver.Core.ChatHistory.ETS.for_session("standard")
  end

  def text_loader, do: BeamWeaver.DocumentLoader.text("standard document")
  def character_splitter, do: BeamWeaver.TextSplitter.character(chunk_size: 10, chunk_overlap: 1)

  def vector_store,
    do: BeamWeaver.VectorStore.ETS.new(embedding: %BeamWeaver.Models.FakeEmbeddingModel{})

  def record_manager, do: BeamWeaver.Indexing.RecordManager.ETS.new(namespace: :standard)

  def retriever do
    store = vector_store()

    docs = [
      BeamWeaver.Core.Document.new!("standard retriever document"),
      BeamWeaver.Core.Document.new!("standard retriever second document")
    ]

    {:ok, [_first, _second]} = BeamWeaver.VectorStore.add_documents(store, docs)
    BeamWeaver.VectorStore.as_retriever(store, k: 1)
  end
end

defmodule BeamWeaver.TestSupport.Conformance.CacheETSTest do
  use BeamWeaver.TestSupport.Conformance.CacheCase,
    cache: &BeamWeaver.TestSupport.Conformance.StandardConformanceFixtures.cache/0
end

defmodule BeamWeaver.TestSupport.Conformance.ChatHistoryETSTest do
  use BeamWeaver.TestSupport.Conformance.ChatHistoryCase,
    session: &BeamWeaver.TestSupport.Conformance.StandardConformanceFixtures.chat_history_session/0
end

defmodule BeamWeaver.TestSupport.Conformance.DocumentLoaderTextTest do
  use BeamWeaver.TestSupport.Conformance.DocumentLoaderCase,
    loader: &BeamWeaver.TestSupport.Conformance.StandardConformanceFixtures.text_loader/0
end

defmodule BeamWeaver.TestSupport.Conformance.TextSplitterCharacterTest do
  use BeamWeaver.TestSupport.Conformance.TextSplitterCase,
    splitter: &BeamWeaver.TestSupport.Conformance.StandardConformanceFixtures.character_splitter/0
end

defmodule BeamWeaver.TestSupport.Conformance.VectorStoreETSTest do
  use BeamWeaver.TestSupport.Conformance.VectorStoreCase,
    store: &BeamWeaver.TestSupport.Conformance.StandardConformanceFixtures.vector_store/0
end

defmodule BeamWeaver.TestSupport.Conformance.RecordManagerETSTest do
  use BeamWeaver.TestSupport.Conformance.RecordManagerCase,
    record_manager: &BeamWeaver.TestSupport.Conformance.StandardConformanceFixtures.record_manager/0
end

defmodule BeamWeaver.TestSupport.Conformance.IndexingETSTest do
  use BeamWeaver.TestSupport.Conformance.IndexingCase,
    vector_store: &BeamWeaver.TestSupport.Conformance.StandardConformanceFixtures.vector_store/0,
    record_manager: &BeamWeaver.TestSupport.Conformance.StandardConformanceFixtures.record_manager/0
end

defmodule BeamWeaver.TestSupport.Conformance.RetrieverVectorStoreTest do
  use BeamWeaver.TestSupport.Conformance.RetrieverCase,
    retriever: &BeamWeaver.TestSupport.Conformance.StandardConformanceFixtures.retriever/0,
    query: "standard",
    k_query: "standard"
end
