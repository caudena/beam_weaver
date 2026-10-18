defmodule BeamWeaver.DocumentPipelineTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.TextSplitter
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.ETS, as: VectorETS

  test "split and tagged documents fill the vector store with their metadata" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    splitter = TextSplitter.character(chunk_size: 10, chunk_overlap: 0)

    {:ok, chunks} =
      TextSplitter.split_documents(splitter, [
        Document.new!("alpha beta gamma", metadata: %{source: "doc-1"})
      ])

    chunks = Enum.map(chunks, &put_in(&1.metadata[:tenant], "a"))

    assert {:ok, [_ | _]} = VectorStore.add_documents(store, chunks)

    assert {:ok, [%Document{metadata: metadata} | _]} =
             VectorStore.similarity_search(store, "alpha", k: 2)

    assert metadata.tenant == "a"
  end
end
