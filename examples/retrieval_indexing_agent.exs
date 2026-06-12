alias BeamWeaver.Core.Document
alias BeamWeaver.Core.Message
alias BeamWeaver.DocumentIndex
alias BeamWeaver.DocumentLoader
alias BeamWeaver.DocumentTransformer
alias BeamWeaver.Models.FakeEmbeddingModel
alias BeamWeaver.Retriever
alias BeamWeaver.VectorStore
alias BeamWeaver.VectorStore.ETS, as: VectorETS

store = VectorETS.new(embedding: %FakeEmbeddingModel{})

index =
  DocumentIndex.new(
    loader: DocumentLoader.text("BeamWeaver uses explicit retrievers.", metadata: %{source: "guide"}),
    transformers: [DocumentTransformer.metadata_map(&Map.put(&1, :tenant, "demo"))],
    vector_store: store
  )

{:ok, %{added: 1}} = DocumentIndex.run(index)
retriever = VectorStore.as_retriever(store, k: 1)
{:ok, [%Document{} = doc]} = Retriever.retrieve(retriever, "retrievers")

IO.puts(Message.text(Message.assistant(doc.content)))
