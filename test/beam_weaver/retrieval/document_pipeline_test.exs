defmodule BeamWeaver.DocumentPipelineTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.ExampleSelector
  alias BeamWeaver.Indexing
  alias BeamWeaver.Indexing.RecordManager.ETS, as: RecordETS
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.TextSplitter
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.ETS, as: VectorETS

  test "splitting, tagging, and indexing documents populates the vector store and records" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()
    splitter = TextSplitter.character(chunk_size: 10, chunk_overlap: 0)

    {:ok, chunks} =
      TextSplitter.split_documents(splitter, [
        Document.new!("alpha beta gamma", metadata: %{source: "doc-1"})
      ])

    chunks = Enum.map(chunks, &put_in(&1.metadata[:tenant], "a"))

    assert {:ok, result} = Indexing.index(store, chunks, record_manager: records, namespace: :docs)
    assert result.added > 0
    assert result.failed == 0

    assert {:ok, [%Document{metadata: metadata} | _]} =
             VectorStore.similarity_search(store, "alpha", k: 2)

    assert metadata.tenant == "a"
  end

  test "indexing counts batch failures as failed without inflating added counts" do
    store = struct(__MODULE__.FailingVectorStore)
    records = RecordETS.new()

    assert {:ok, result} =
             Indexing.index(store, [Document.new!("alpha", id: "a")],
               record_manager: records,
               batch_size: 1
             )

    assert result.added == 0
    assert result.updated == 0
    assert result.failed == 1
    assert [%Error{type: :vector_store_failed}] = result.errors
  end

  test "MMR and metadata-filter example selectors return stable example maps" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})

    assert {:ok, _ids} =
             VectorStore.add_documents(store, [
               Document.new!("alpha", metadata: %{input: "a", output: "A", kind: "keep"}),
               Document.new!("beta", metadata: %{input: "b", output: "B", kind: "drop"})
             ])

    selector =
      store
      |> ExampleSelector.mmr_vectorstore(k: 2, fetch_k: 2)
      |> ExampleSelector.metadata_filter(&(&1.kind == "keep"))

    assert {:ok, [%{input: "a", output: "A", kind: "keep"}]} =
             ExampleSelector.select(selector, "alpha", k: 2)
  end

  test "example selectors add examples and expose selection helpers" do
    selector = ExampleSelector.length_based([%{input: "short"}], max_length: 4)

    assert {:ok, selector} = ExampleSelector.add_example(selector, %{input: "next"})

    assert {:ok, [%{input: "short"}, %{input: "next"}]} =
             ExampleSelector.select(selector, %{input: "query"})

    assert ExampleSelector.sorted_values(%{b: "two", a: "one"}) == ["one", "two"]
  end

  test "semantic and MMR example selectors can be built from examples" do
    examples = [
      %{input: "alpha", output: "A", keep: true},
      %{input: "beta", output: "B", keep: false}
    ]

    embedding = %FakeEmbeddingModel{}

    assert {:ok, semantic} =
             ExampleSelector.semantic_similarity(examples, embedding,
               k: 1,
               input_keys: [:input],
               example_keys: [:input, :output]
             )

    assert {:ok, [%{input: "alpha", output: "A"}]} =
             ExampleSelector.select(semantic, %{input: "alpha"})

    assert {:ok, id} =
             ExampleSelector.add_example(semantic, %{input: "gamma", output: "G"})

    assert is_binary(id)

    assert {:ok, mmr} =
             ExampleSelector.max_marginal_relevance(examples, embedding,
               k: 1,
               fetch_k: 2,
               input_keys: [:input]
             )

    assert {:ok, [%{input: _input, output: _output, keep: _keep}]} =
             ExampleSelector.select(mmr, %{input: "alpha"})

    assert {:ok, _selector} =
             ExampleSelector.from_examples(examples, embedding, k: 1)
  end

  defmodule FailingVectorStore do
    @behaviour BeamWeaver.VectorStore

    alias BeamWeaver.Core.Error

    defstruct []

    def add_documents(_store, _documents, _opts),
      do: {:error, Error.new(:vector_store_failed, "simulated vector failure")}

    def delete(_store, _ids, _opts), do: :ok
    def similarity_search(_store, _query, _opts), do: {:ok, []}
    def similarity_search_with_score(_store, _query, _opts), do: {:ok, []}
    def similarity_search_by_vector(_store, _vector, _opts), do: {:ok, []}
    def max_marginal_relevance_search(_store, _query, _opts), do: {:ok, []}
  end
end
