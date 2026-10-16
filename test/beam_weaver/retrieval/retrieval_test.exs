defmodule BeamWeaver.RetrievalTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolResult
  alias BeamWeaver.ExampleSelector
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.Retriever
  alias BeamWeaver.TextSplitter
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.ETS, as: ETSVectorStore

  # Fixed vectors: "a" and "a2" are near duplicates close to the query, "b"
  # points elsewhere.
  defmodule FixedEmbeddings do
    @behaviour BeamWeaver.Core.EmbeddingModel

    @vectors %{
      "q" => [1.0, 0.0],
      "a" => [0.995, 0.0998],
      "a2" => [0.99, 0.141],
      "b" => [0.6, -0.8]
    }

    defstruct []

    @impl true
    def embed_documents(_model, texts, _opts), do: {:ok, Enum.map(texts, &Map.fetch!(@vectors, &1))}

    @impl true
    def embed_query(_model, text, _opts), do: {:ok, Map.fetch!(@vectors, text)}
  end

  test "text splitter preserves metadata and start indexes" do
    splitter = TextSplitter.character(chunk_size: 8, chunk_overlap: 2, add_start_index: true)
    doc = Document.new!("alpha beta gamma", metadata: %{path: "doc.txt"})

    assert {:ok, stream} = TextSplitter.split_documents(splitter, [doc])
    chunks = Enum.to_list(stream)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(&1.metadata.path == "doc.txt"))
    assert Enum.all?(chunks, &is_integer(&1.metadata.start_index))
  end

  test "add_documents takes the splitter's stream, or any enumerable of documents" do
    store = ETSVectorStore.new(embedding: %FakeEmbeddingModel{})
    splitter = TextSplitter.recursive_character(chunk_size: 12, chunk_overlap: 0)
    {:ok, chunks} = TextSplitter.split_documents(splitter, [Document.new!("alpha beta gamma delta")])

    assert {:ok, [_, _]} = VectorStore.add_documents(store, chunks)
    assert {:ok, [_]} = VectorStore.add_documents(store, Stream.map(["epsilon"], &Document.new!/1))
    assert {:ok, ^store} = VectorStore.from_documents(store, MapSet.new([Document.new!("zeta")]))

    {:ok, bad} = TextSplitter.split_documents(splitter, [42])
    assert {:error, %{type: :invalid_documents}} = VectorStore.add_documents(store, bad)
    assert {:error, %{type: :invalid_documents}} = VectorStore.add_documents(store, :not_documents)
  end

  test "an MMR retriever uses its mmr_lambda, and retrieve/3 can override it" do
    store = ETSVectorStore.new(embedding: %FixedEmbeddings{})
    assert {:ok, _ids} = VectorStore.add_documents(store, Enum.map(["a", "a2", "b"], &Document.new!(&1, id: &1)))

    relevant = VectorStore.as_retriever(store, search_type: :mmr, k: 2, mmr_lambda: 1.0)
    varied = VectorStore.as_retriever(store, search_type: :mmr, k: 2, mmr_lambda: 0.0)

    assert {:ok, [%{id: "a"}, %{id: "a2"}]} = Retriever.retrieve(relevant, "q")
    assert {:ok, [%{id: "a"}, %{id: "b"}]} = Retriever.retrieve(varied, "q")
    assert {:ok, [%{id: "a"}, %{id: "b"}]} = Retriever.retrieve(relevant, "q", mmr_lambda: 0.0)
  end

  test "ETS vectorstore supports similarity search, filtering, and retriever conversion" do
    store = ETSVectorStore.new(embedding: %FakeEmbeddingModel{})

    docs = [
      Document.new!("alpha", metadata: %{group: "a"}),
      Document.new!("beta", metadata: %{group: "b"})
    ]

    assert {:ok, ids} = VectorStore.add_documents(store, docs)
    assert length(ids) == 2

    assert {:ok, [%Document{}]} = VectorStore.similarity_search(store, "alpha", k: 1)

    assert {:ok, [%Document{metadata: %{group: "b"}}]} =
             VectorStore.similarity_search(store, "beta", k: 1, filter: %{group: "b"})

    retriever = VectorStore.as_retriever(store, k: 1)
    assert {:ok, [%Document{}]} = Retriever.retrieve(retriever, "alpha")
  end

  test "retriever as_tool returns model-facing content and optional document artifacts" do
    store = ETSVectorStore.new(embedding: %FakeEmbeddingModel{})

    docs = [
      Document.new!("alpha policy", metadata: %{path: "alpha.md"}),
      Document.new!("alpha appendix", metadata: %{path: "appendix.md"})
    ]

    assert {:ok, _ids} = VectorStore.add_documents(store, docs)
    retriever = VectorStore.as_retriever(store, k: 2)

    content_tool =
      Retriever.as_tool(retriever,
        name: "policy_search",
        description: "Search policies.",
        document_separator: "\n---\n"
      )

    assert {:ok, content} = Tool.invoke(content_tool, %{"query" => "alpha"})
    assert content =~ "alpha policy"
    assert content =~ "\n---\n"

    prompt_tool =
      Retriever.as_tool(retriever,
        name: "policy_search",
        description: "Search policies.",
        document_prompt: BeamWeaver.Prompt.string("{path}: {content}"),
        document_separator: "\n"
      )

    assert {:ok, prompt_content} = Tool.invoke(prompt_tool, %{"query" => "alpha"})
    assert prompt_content =~ "alpha.md: alpha policy"
    assert prompt_content =~ "appendix.md: alpha appendix"

    artifact_tool =
      Retriever.as_tool(retriever,
        name: "policy_search",
        description: "Search policies.",
        response_format: :content_and_artifact
      )

    assert {:ok, %ToolResult{content: raw_content, artifact: [%Document{} | _]}} =
             Tool.invoke(artifact_tool, %{"query" => "alpha"})

    assert raw_content =~ "alpha"

    assert {:ok, message} =
             Tool.invoke(artifact_tool, %{
               type: "tool_call",
               name: "policy_search",
               id: "call-retriever",
               args: %{"query" => "alpha"}
             })

    assert message.role == :tool
    assert message.tool_call_id == "call-retriever"
    assert message.content =~ "alpha"
    assert [%Document{} | _] = message.artifacts
  end

  test "an agent keeps the documents a retriever tool found as the tool message's artifact" do
    store = ETSVectorStore.new(embedding: %FakeEmbeddingModel{})
    assert {:ok, _ids} = VectorStore.add_documents(store, [Document.new!("Refunds take 5 days.", id: "refunds")])

    tool =
      Retriever.as_tool(VectorStore.as_retriever(store, k: 1),
        name: "search_help_center",
        response_format: "content_and_artifact"
      )

    model =
      BeamWeaver.Models.init_chat_model!("fake:chat",
        responses: [
          BeamWeaver.Models.FakeChatModel.tool_call("search_help_center", %{"query" => "refunds"}),
          "Refunds take 5 days."
        ]
      )

    {:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [tool])
    assert {:ok, %{messages: messages}} = BeamWeaver.Agent.invoke(agent, %{messages: ["How long do refunds take?"]})

    tool_message = Enum.find(messages, &(&1.role == :tool))
    assert tool_message.content == "Refunds take 5 days."
    assert [%Document{id: "refunds"}] = tool_message.metadata.artifact
  end

  test "indexing assigns stable IDs and example selectors choose bounded examples" do
    store = ETSVectorStore.new(embedding: %FakeEmbeddingModel{})
    docs = [Document.new!("alpha", metadata: %{example: %{input: "a", output: "b"}})]

    assert {:ok, result} = BeamWeaver.Indexing.index(store, docs)
    assert result.added == 1

    selector =
      ExampleSelector.length_based([%{input: "short"}, %{input: String.duplicate("x", 100)}],
        max_length: 2
      )

    assert {:ok, [%{input: "short"}]} = ExampleSelector.select(selector, %{}, k: 2)
  end
end
