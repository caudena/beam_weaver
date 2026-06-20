defmodule BeamWeaver.TextSplitter.SharedTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.TextSplitter.Shared

  test "chunks_to_documents reports character start_index for non-ascii text" do
    text = "héllo wörld foo"
    document = Document.new!(text)
    chunks = ["wörld", "foo"]

    docs = Shared.chunks_to_documents(chunks, document, true)

    assert Enum.map(docs, & &1.metadata.start_index) == [
             String.length("héllo "),
             String.length("héllo wörld ")
           ]

    assert Enum.map(docs, &String.slice(text, &1.metadata.start_index, String.length(&1.content))) ==
             chunks
  end
end
