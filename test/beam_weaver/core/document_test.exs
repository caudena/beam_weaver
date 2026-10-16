defmodule BeamWeaver.Core.DocumentTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document

  test "builds pattern-matchable documents with string ids and metadata" do
    assert {:ok, %Document{id: "123", content: "hello", metadata: %{source: "test"}}} =
             Document.new("hello", id: 123, metadata: %{source: "test"})
  end

  test "normalizes accepted document ids without requiring ids" do
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
    doc = Document.new!("Hello, World!", metadata: %{source: "fixture"})

    inspected = inspect(doc)
    assert inspected =~ "BeamWeaver.Core.Document"
    assert inspected =~ "Hello, World!"
    assert inspected =~ "source"
  end

  test "from/1 builds documents from documents, strings, and :content maps" do
    doc = Document.new!("hello", id: "d1")

    assert {:ok, ^doc} = Document.from(doc)
    assert {:ok, %Document{content: "hi", metadata: %{}}} = Document.from("hi")

    assert {:ok, %Document{id: "7", content: "hi", metadata: %{source: "s"}}} =
             Document.from(%{content: "hi", id: 7, metadata: %{source: "s"}})

    assert {:error, %{type: :invalid_document}} = Document.from(%{"content" => "hi"})
    assert {:error, %{type: :invalid_document}} = Document.from(:nope)
  end

  test "rejects invalid document content and metadata" do
    assert {:error, content_error} = Document.new(:not_text)
    assert content_error.type == :invalid_content

    assert {:error, metadata_error} = Document.new("hello", metadata: [source: "test"])
    assert metadata_error.type == :invalid_metadata
  end
end
