defmodule BeamWeaver.Tools.FileSearch.FilesystemTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Tools.FileSearch

  test "literal snippet handles multibyte content whose downcase changes byte length" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_file_search_multibyte_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    content = String.duplicate("İ", 60) <> "Q"
    File.write!(Path.join(root, "a.md"), content)

    tool =
      FileSearch.new(
        roots: [root],
        include: ["**/*.md"],
        max_results: 5,
        snippet_bytes: 8
      )

    assert {:ok, [result]} = Tool.invoke(tool, %{"query" => "Q"})
    assert result.metadata.relative_path == "a.md"
    assert result.content =~ "q"
    assert String.valid?(result.content)
  end

  test "literal snippet stays aligned when a multibyte char precedes the match" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_file_search_align_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(Path.join(root, "a.md"), String.duplicate("İ", 50) <> "endneedle")

    tool =
      FileSearch.new(
        roots: [root],
        include: ["**/*.md"],
        max_results: 5,
        snippet_bytes: 240
      )

    assert {:ok, [result]} = Tool.invoke(tool, %{"query" => "endneedle"})
    assert result.content =~ "endneedle"
    assert String.valid?(result.content)
  end
end
