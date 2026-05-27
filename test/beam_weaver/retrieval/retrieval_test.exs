defmodule BeamWeaver.RetrievalTest do
  use ExUnit.Case, async: true

  # Upstream references:
  # - langchain/libs/text-splitters tests for chunk size/overlap and metadata propagation
  # - langchain/libs/standard-tests retriever/vectorstore behavior suites

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.DocumentLoader
  alias BeamWeaver.ExampleSelector
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.Retriever
  alias BeamWeaver.TextSplitter
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.ETS, as: ETSVectorStore

  test "document loader returns a lazy enumerable of documents" do
    assert {:ok, stream} =
             DocumentLoader.load(DocumentLoader.text("hello", metadata: %{source: "inline"}))

    assert [%Document{content: "hello", metadata: %{source: "inline"}}] = Enum.to_list(stream)
  end

  test "path document loader is lazy and preserves blob metadata" do
    # Upstream reference:
    # langchain_core document loader base tests for lazy loading behavior.
    path =
      Path.join(System.tmp_dir!(), "beam_weaver_loader_#{System.unique_integer([:positive])}.txt")

    File.write!(path, "loaded from disk")

    on_exit(fn -> File.rm(path) end)

    assert {:ok, stream} = DocumentLoader.load(DocumentLoader.paths([path]))
    File.rm!(path)

    assert_raise RuntimeError, fn -> Enum.to_list(stream) end

    File.write!(path, "loaded from disk")

    assert {:ok, stream} = DocumentLoader.load(DocumentLoader.paths([path]))
    assert [%Document{content: "loaded from disk", metadata: metadata}] = Enum.to_list(stream)
    assert metadata.source == path
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
        document_prompt: BeamWeaver.Prompt.string("{path}: {page_content}"),
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

    assert {:ok, raw_content} = Tool.invoke(artifact_tool, %{"query" => "alpha"})
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
