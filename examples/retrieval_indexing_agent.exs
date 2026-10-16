alias BeamWeaver.Core.Document
alias BeamWeaver.Core.Message
alias BeamWeaver.Indexing
alias BeamWeaver.Models.FakeEmbeddingModel
alias BeamWeaver.Retriever
alias BeamWeaver.TextSplitter
alias BeamWeaver.VectorStore
alias BeamWeaver.VectorStore.ETS, as: VectorETS

store = VectorETS.new(embedding: %FakeEmbeddingModel{})

{:ok, chunks} =
  TextSplitter.split_documents(TextSplitter.character(chunk_size: 200), [
    Document.new!("BeamWeaver uses explicit retrievers.", metadata: %{source: "guide"})
  ])

docs = Enum.map(chunks, &put_in(&1.metadata[:tenant], "demo"))

{:ok, %{added: 1}} = Indexing.index(store, docs)
retriever = VectorStore.as_retriever(store, k: 1)
{:ok, [%Document{} = doc]} = Retriever.retrieve(retriever, "retrievers")

IO.puts(Message.text(Message.assistant(doc.content)))
