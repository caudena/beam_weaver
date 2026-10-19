defmodule BeamWeaver.TextSplitter.SharedTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.TextSplitter

  defp start_indexes(text, opts) do
    splitter = TextSplitter.character([separator: " ", add_start_index: true] ++ opts)
    {:ok, stream} = TextSplitter.split_documents(splitter, [Document.new!(text)])
    Enum.map(stream, &{&1.content, &1.metadata.start_index})
  end

  test "start_index counts characters in non-ascii text" do
    assert start_indexes("héllo wörld foo", chunk_size: 11, chunk_overlap: 0) == [
             {"héllo wörld", 0},
             {"foo", String.length("héllo wörld ")}
           ]
  end

  test "start_index advances through repeated overlapping chunks" do
    assert start_indexes("foo foo foo", chunk_size: 7, chunk_overlap: 4) == [{"foo foo", 0}, {"foo foo", 4}]
  end
end
