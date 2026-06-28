defmodule BeamWeaver.Filesystem.FormatTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Filesystem.Format

  describe "format_content_with_line_numbers/2 chunking" do
    test "does not corrupt multibyte UTF-8 characters when splitting long lines" do
      line = String.duplicate("é", 10)

      result = Format.format_content_with_line_numbers(line, max_line_length: 4)

      assert String.valid?(result)
      refute String.contains?(result, "�")

      rejoined =
        result
        |> String.split("\n")
        |> Enum.map_join(fn part -> part |> String.split("\t", parts: 2) |> List.last() end)

      assert rejoined == line
    end

    test "splits emoji lines on codepoint boundaries" do
      line = String.duplicate("😀", 6)

      result = Format.format_content_with_line_numbers(line, max_line_length: 2)

      assert String.valid?(result)

      rejoined =
        result
        |> String.split("\n")
        |> Enum.map_join(fn part -> part |> String.split("\t", parts: 2) |> List.last() end)

      assert rejoined == line
    end

    test "leaves short lines untouched with line numbers" do
      result = Format.format_content_with_line_numbers("hello", max_line_length: 5_000)

      assert result == "     1\thello"
    end
  end
end
