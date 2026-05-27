defmodule BeamWeaver.Core.DocumentTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Blob
  alias BeamWeaver.Core.Document

  test "builds pattern-matchable documents with string ids and metadata" do
    assert {:ok, %Document{id: "123", content: "hello", metadata: %{source: "test"}, type: "Document"}} =
             Document.new("hello", id: 123, metadata: %{source: "test"})
  end

  test "normalizes accepted document ids without requiring ids" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/documents/test_document.py
    assert {:ok, %Document{id: nil, content: "hello", metadata: %{}}} = Document.new("hello")
    assert {:ok, %Document{id: nil}} = Document.new("hello", id: nil)
    assert {:ok, %Document{id: "doc-1"}} = Document.new("hello", id: "doc-1")
    assert {:ok, %Document{id: "7"}} = Document.new("hello", id: 7)
  end

  test "document validation accepts only BeamWeaver document shapes" do
    assert :ok = Document.validate(Document.new!("hello", metadata: %{page: 1}))

    assert {:error, error} = Document.validate(%{content: "hello", metadata: %{}})
    assert error.type == :invalid_document

    assert {:error, error} = Document.validate(%Document{content: :bad, metadata: %{}})
    assert error.type == :invalid_document
  end

  test "documents inspect with content and metadata for debugging" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/documents/test_str.py
    doc = Document.new!("Hello, World!", metadata: %{source: "fixture"})

    inspected = inspect(doc)
    assert inspected =~ "BeamWeaver.Core.Document"
    assert inspected =~ "Hello, World!"
    assert inspected =~ "source"
  end

  test "documents expose LangChain-compatible namespace and prompt string" do
    assert Document.serializable?()
    assert Document.lc_namespace() == ["langchain", "schema", "document"]

    assert to_string(Document.new!("Hello")) == "page_content='Hello'"

    assert to_string(Document.new!("Hello", metadata: %{source: "fixture"})) ==
             "page_content='Hello' metadata=%{source: \"fixture\"}"
  end

  test "blobs read memory and path data with source and mimetype metadata" do
    assert {:ok, memory} =
             Blob.from_data("hello", id: 123, source: "inline", mime_type: "text/plain")

    assert memory.id == "123"
    assert memory.mimetype == "text/plain"
    assert Blob.source(memory) == "inline"
    assert Blob.repr(memory) == "Blob 123 inline"
    assert {:ok, "hello"} = Blob.as_string(memory)
    assert {:ok, "hello"} = Blob.as_bytes(memory)

    assert {:ok, "hello"} =
             Blob.as_bytes_io(memory, fn io ->
               IO.read(io, :eof)
             end)

    path = Path.join(System.tmp_dir!(), "beam-weaver-blob-#{System.unique_integer()}.txt")
    File.write!(path, "from path")

    try do
      assert {:ok, path_blob} = Blob.from_path(path)
      assert path_blob.path == path
      assert path_blob.mimetype == "text/plain"
      assert Blob.source(path_blob) == path
      assert {:ok, "from path"} = Blob.as_string(path_blob)
    after
      File.rm(path)
    end
  end

  test "rejects invalid document content and metadata" do
    assert {:error, content_error} = Document.new(:not_text)
    assert content_error.type == :invalid_content

    assert {:error, metadata_error} = Document.new("hello", metadata: [source: "test"])
    assert metadata_error.type == :invalid_metadata
  end
end
