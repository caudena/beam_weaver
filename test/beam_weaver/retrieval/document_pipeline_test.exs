defmodule BeamWeaver.DocumentPipelineTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Blob
  alias BeamWeaver.BlobLike
  alias BeamWeaver.BlobLoader
  alias BeamWeaver.BlobParser
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.DocumentCompressor
  alias BeamWeaver.DocumentIndex
  alias BeamWeaver.DocumentLoader
  alias BeamWeaver.DocumentTransformer
  alias BeamWeaver.ExampleSelector
  alias BeamWeaver.Indexing
  alias BeamWeaver.Indexing.RecordManager.ETS, as: RecordETS
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.TextSplitter
  alias BeamWeaver.Transport.URLPolicy
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.ETS, as: VectorETS

  test "BlobLike converts maps without creating atoms from untrusted keys" do
    key = "beam_weaver_untrusted_#{System.unique_integer([:positive])}"
    before? = atom_exists?(key)

    assert {:ok, %Blob{data: "hello", metadata: %{"source" => "inline"}}} =
             BlobLike.to_blob(%{
               "data" => "hello",
               "metadata" => %{"source" => "inline"},
               key => "ignored"
             })

    assert before? == atom_exists?(key)
  end

  test "blob loaders and parsers lazily produce documents" do
    loader =
      BlobLoader.data([
        %{
          "data" => ~s({"content":"one","metadata":{"kind":"json"}}),
          "metadata" => %{"source" => "memory"}
        }
      ])

    document_loader = DocumentLoader.blobs(loader, BlobParser.json())

    assert {:ok, stream} = DocumentLoader.load(document_loader)
    assert [%Document{content: "one", metadata: metadata}] = Enum.to_list(stream)
    assert metadata == %{"source" => "memory", "kind" => "json"}

    assert {:ok, blobs} = BlobLoader.yield_blobs(loader)
    assert [%Blob{}] = Enum.to_list(blobs)

    assert {:ok, parsed} =
             BlobParser.parse_all(BlobParser.json(), %{
               "data" => ~s({"content":"all"}),
               "metadata" => %{"source" => "parse_all"}
             })

    assert [%Document{content: "all"}] = parsed
  end

  test "document loaders expose lazy, eager, split, and Task-backed loading helpers" do
    loader = DocumentLoader.text("alpha beta gamma", metadata: %{source: "inline"})

    assert {:ok, lazy} = DocumentLoader.lazy_load(loader)
    assert [%Document{content: "alpha beta gamma"}] = Enum.to_list(lazy)

    assert {:ok, [%Document{metadata: %{source: "inline"}}]} = DocumentLoader.load_all(loader)

    splitter = TextSplitter.character(chunk_size: 6, chunk_overlap: 0, separator: " ")
    assert {:ok, split_stream} = DocumentLoader.load_and_split(loader, splitter)
    assert Enum.map(split_stream, & &1.content) == ["alpha", "beta", "gamma"]

    assert {:ok, [%Document{content: "alpha beta gamma"}]} =
             DocumentLoader.async_load_all(loader) |> BeamWeaver.Core.Async.await()

    assert {:ok, async_lazy} =
             DocumentLoader.async_lazy_load(loader) |> BeamWeaver.Core.Async.await()

    assert [%Document{content: "alpha beta gamma"}] = Enum.to_list(async_lazy)
  end

  test "JSON-lines and simple HTML parsers preserve blob metadata" do
    assert {:ok, docs} =
             BlobParser.parse(
               BlobParser.json_lines(),
               %{
                 "data" => ~s({"content":"a"}\n{"content":"b","metadata":{"rank":2}}),
                 "metadata" => %{"source" => "jsonl"}
               }
             )

    assert Enum.map(docs, & &1.content) == ["a", "b"]
    assert Enum.at(docs, 1).metadata == %{"source" => "jsonl", "rank" => 2}

    assert {:ok, [%Document{content: "Title & text"}]} =
             BlobParser.parse(BlobParser.html_text(), "<h1>Title</h1><p>&amp; text</p>")
  end

  test "CSV and TSV parsers create documents without atom creation" do
    key = "beam_weaver_csv_key_#{System.unique_integer([:positive])}"
    before? = atom_exists?(key)

    assert {:ok, docs} =
             BlobParser.parse(
               BlobParser.csv(content_key: "body", metadata_keys: ["id", key]),
               %{
                 "data" => "id,body,#{key}\n1,hello,keep\n2,\"hello, again\",drop",
                 "metadata" => %{"source" => "csv"}
               }
             )

    assert [
             %Document{
               content: "hello",
               metadata: %{"source" => "csv", "id" => "1", ^key => "keep"}
             },
             %Document{
               content: "hello, again",
               metadata: %{"source" => "csv", "id" => "2", ^key => "drop"}
             }
           ] = docs

    assert before? == atom_exists?(key)

    assert {:ok, [%Document{content: "world", metadata: %{"source" => "tsv", "id" => "1"}}]} =
             BlobParser.parse(
               BlobParser.tsv(content_key: "body", metadata_keys: ["id"]),
               %{"data" => "id\tbody\n1\tworld", "metadata" => %{"source" => "tsv"}}
             )
  end

  test "URL policy rejects unsafe URLs before loader transport calls" do
    assert {:error, %Error{type: :unsafe_url}} = URLPolicy.validate("http://example.com")
    assert {:error, %Error{type: :unsafe_url}} = URLPolicy.validate("https://localhost/docs")
    assert {:error, %Error{type: :unsafe_url}} = URLPolicy.validate("https://127.0.0.1/docs")

    assert {:ok, "https://example.test/docs"} =
             URLPolicy.validate("https://example.test/docs", allowed_hosts: ["example.test"])

    assert {:error, %Error{type: :unsafe_url}} =
             URLPolicy.validate("https://other.test/docs", allowed_hosts: ["example.test"])
  end

  test "URL document loader fetches through explicit transport and enforces max bytes" do
    loader =
      DocumentLoader.url("https://example.test/doc",
        transport: __MODULE__.URLTransport,
        max_bytes: 32,
        metadata: %{tenant: "a"}
      )

    assert {:ok, stream} = DocumentLoader.load(loader)

    assert [
             %Document{
               content: "remote body",
               metadata: %{source: "https://example.test/doc", status: 200, tenant: "a"}
             }
           ] = Enum.to_list(stream)

    too_small =
      BlobLoader.url("https://example.test/doc",
        transport: __MODULE__.URLTransport,
        max_bytes: 4
      )

    assert {:ok, stream} = BlobLoader.load(too_small)

    assert_raise RuntimeError, "URL loader response exceeded max_bytes", fn ->
      Enum.to_list(stream)
    end
  end

  test "JSON-lines parser returns tagged errors for malformed lines" do
    # Upstream reference:
    # errors rather than leaking JSON decoder exceptions.
    assert {:error, %Error{type: :blob_parse_error, message: "invalid JSON-lines blob"} = error} =
             BlobParser.parse(
               BlobParser.json_lines(),
               %{
                 "data" => ~s({"content":"ok"}\nnot-json),
                 "metadata" => %{"source" => "bad-jsonl"}
               }
             )

    assert error.details.reason =~ "unexpected byte"
  end

  test "JSON parser custom string keys do not create atoms and preserve metadata" do
    # Upstream reference:
    # string-key JSON boundary and no-atom-creation contract.
    content_key = "beam_weaver_content_key_#{System.unique_integer([:positive])}"
    metadata_key = "beam_weaver_metadata_key_#{System.unique_integer([:positive])}"
    before_content? = atom_exists?(content_key)
    before_metadata? = atom_exists?(metadata_key)

    assert {:ok, [%Document{content: "custom", metadata: metadata}]} =
             BlobParser.parse(
               BlobParser.json(content_key: content_key, metadata_key: metadata_key),
               %{
                 "data" =>
                   BeamWeaver.JSON.encode!(%{
                     content_key => "custom",
                     metadata_key => %{"rank" => 1}
                   }),
                 "metadata" => %{"source" => "custom-json"}
               }
             )

    assert metadata == %{"source" => "custom-json", "rank" => 1}
    assert before_content? == atom_exists?(content_key)
    assert before_metadata? == atom_exists?(metadata_key)
  end

  test "document transformers are lazy and return tagged errors for bad output" do
    docs = [Document.new!("Alpha", metadata: %{keep?: true})]

    transformer =
      DocumentTransformer.content_map(&String.downcase/1)

    assert {:ok, stream} = DocumentTransformer.transform(transformer, docs)
    assert [%Document{content: "alpha"}] = Enum.to_list(stream)

    assert {:ok, stream} =
             DocumentTransformer.transform(
               DocumentTransformer.metadata_filter(&Map.get(&1, :keep?)),
               docs
             )

    assert [%Document{content: "Alpha"}] = Enum.to_list(stream)

    assert {:ok, stream} =
             DocumentTransformer.transform(
               DocumentTransformer.content_map(fn _ -> :bad end),
               docs
             )

    assert_raise RuntimeError, "content transformer must return a string", fn ->
      Enum.to_list(stream)
    end

    assert {:ok, async_stream} =
             DocumentTransformer.async_transform(transformer, docs)
             |> BeamWeaver.Core.Async.await()

    assert [%Document{content: "alpha"}] = Enum.to_list(async_stream)
  end

  test "document compressors truncate retrieved documents through contextual retriever" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    assert {:ok, [_id]} = VectorStore.add_documents(store, [Document.new!("abcdefghij")])

    retriever =
      store
      |> VectorStore.as_retriever(k: 1)
      |> DocumentCompressor.contextual_retriever(DocumentCompressor.truncation(max_characters: 4))

    assert {:ok, [%Document{content: "abcd"}]} =
             BeamWeaver.Retriever.retrieve(retriever, "abcd")

    assert {:ok, [%Document{content: "abcd"}]} =
             DocumentCompressor.async_compress(
               DocumentCompressor.truncation(max_characters: 4),
               [Document.new!("abcdefghij")],
               "abcd"
             )
             |> BeamWeaver.Core.Async.await()
  end

  test "DocumentIndex orchestrates loader, parser, splitter, transformers, vectorstore, and records" do
    store = VectorETS.new(embedding: %FakeEmbeddingModel{})
    records = RecordETS.new()

    index =
      DocumentIndex.new(
        blob_loader:
          BlobLoader.data(%{
            "data" => ~s({"content":"alpha beta gamma","metadata":{"source":"doc-1"}})
          }),
        blob_parser: BlobParser.json(),
        splitter: TextSplitter.character(chunk_size: 10, chunk_overlap: 0),
        transformers: [DocumentTransformer.metadata_map(&Map.put(&1, :tenant, "a"))],
        vector_store: store,
        record_manager: records,
        namespace: :docs
      )

    assert {:ok, result} = DocumentIndex.run(index)
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

  test "example selectors add examples and expose Task-backed selection helpers" do
    selector = ExampleSelector.length_based([%{input: "short"}], max_length: 4)

    assert {:ok, selector} = ExampleSelector.add_example(selector, %{input: "next"})

    assert {:ok, [%{input: "short"}, %{input: "next"}]} =
             ExampleSelector.async_select(selector, %{input: "query"})
             |> BeamWeaver.Core.Async.await()

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
             ExampleSelector.async_add_example(semantic, %{input: "gamma", output: "G"})
             |> BeamWeaver.Core.Async.await()

    assert is_binary(id)

    assert {:ok, mmr} =
             ExampleSelector.max_marginal_relevance(examples, embedding,
               k: 1,
               fetch_k: 2,
               input_keys: [:input]
             )

    assert {:ok, [%{input: _input, output: _output, keep: _keep}]} =
             ExampleSelector.async_select(mmr, %{input: "alpha"})
             |> BeamWeaver.Core.Async.await()

    assert {:ok, _selector} =
             ExampleSelector.async_from_examples(examples, embedding, k: 1)
             |> BeamWeaver.Core.Async.await()
  end

  defp atom_exists?(name) do
    is_atom(String.to_existing_atom(name))
  rescue
    ArgumentError -> false
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

  defmodule URLTransport do
    @behaviour BeamWeaver.Transport

    alias BeamWeaver.Transport.Request
    alias BeamWeaver.Transport.Response

    def request(%Request{url: "https://example.test/doc"}, _opts) do
      {:ok, Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: "remote body")}
    end
  end
end
