alias BeamWeaver.Agent
alias BeamWeaver.Core.Document
alias BeamWeaver.Core.Message
alias BeamWeaver.Models.FakeChatModel
alias BeamWeaver.Models.FakeEmbeddingModel
alias BeamWeaver.Retriever
alias BeamWeaver.TextSplitter
alias BeamWeaver.VectorStore

store = VectorStore.ETS.new(embedding: %FakeEmbeddingModel{})

{:ok, chunks} =
  TextSplitter.split_documents(TextSplitter.character(chunk_size: 200), [
    Document.new!("Refunds reach the original card within 5 business days.", metadata: %{"source" => "refunds.md"}),
    Document.new!("Express shipping arrives the next business day.", metadata: %{"source" => "shipping.md"})
  ])

{:ok, _ids} = VectorStore.add_documents(store, chunks)

search =
  store
  |> VectorStore.as_retriever(k: 1)
  |> Retriever.as_tool(name: "search_help_center", description: "Search Acme's help center for policies.")

{:ok, agent} =
  Agent.build(
    model: %FakeChatModel{
      responses: [
        FakeChatModel.tool_call("search_help_center", %{"query" => "refund timing"}),
        "Refunds reach your card within 5 business days."
      ]
    },
    tools: [search]
  )

{:ok, result} = Agent.invoke(agent, %{messages: ["How long do refunds take?"]})

IO.puts(result.messages |> List.last() |> Message.text())
