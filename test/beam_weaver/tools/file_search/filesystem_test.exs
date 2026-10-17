defmodule BeamWeaver.Tools.FileSearch.FilesystemTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Tools.FileSearch

  @moduletag :tmp_dir

  test "literal snippet handles multibyte content whose downcase changes byte length", %{tmp_dir: root} do
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
    assert result.content =~ "Q"
    assert String.valid?(result.content)
  end

  test "literal snippet stays aligned when a multibyte char precedes the match", %{tmp_dir: root} do
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

  test "literal snippets preserve source case", %{tmp_dir: root} do
    File.write!(Path.join(root, "a.md"), "Before MixedCaseNeedle After")

    tool = FileSearch.new(roots: [root], include: ["**/*.md"], max_results: 5, snippet_bytes: 80)

    assert {:ok, [result]} = Tool.invoke(tool, %{"query" => "mixedcaseneedle"})
    assert result.content =~ "MixedCaseNeedle"
    refute result.content =~ "mixedcaseneedle"
  end

  test "count mode includes filename matches", %{tmp_dir: root} do
    File.write!(Path.join(root, "NeedleName.md"), "body without query")

    tool = FileSearch.new(roots: [root], include: ["**/*.md"], max_results: 5)

    assert {:ok, [result]} =
             Tool.invoke(tool, %{"query" => "needlename", "output_mode" => "count"})

    assert result.content == "1"
    assert result.metadata.match_count == 1
    assert result.metadata.line_match_count == 0
    assert result.metadata.path_match? == true
  end
end
