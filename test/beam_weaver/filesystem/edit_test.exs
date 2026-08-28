defmodule BeamWeaver.Filesystem.EditTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Filesystem.{Edit, Format}

  describe "replacement/4" do
    test "replaces one exact byte sequence by default" do
      assert {:ok, 1, "before new after"} =
               Edit.replacement("before old after", "old", "new")
    end

    test "reports empty, missing, and ambiguous old text with typed errors" do
      assert {:error, :empty_old_text} = Edit.replacement("content", "", "new")
      assert {:error, :not_found} = Edit.replacement("content", "missing", "new")

      assert {:error, {:multiple_occurrences, 2}} =
               Edit.replacement("old and old", "old", "new")
    end

    test "replace_all replaces every non-overlapping occurrence" do
      assert {:ok, 3, "xxx"} =
               Edit.replacement("aaaaaa", "aa", "x", replace_all: true)
    end

    test "supports arbitrary binary content" do
      assert {:ok, 1, <<0, 9, 255>>} =
               Edit.replacement(<<0, 1, 255>>, <<1>>, <<9>>)
    end

    test "stops counting when the caller's occurrence cap is exceeded" do
      assert {:error, {:occurrence_limit_exceeded, 2}} =
               Edit.replacement("aaa", "a", "b", replace_all: true, max_occurrences: 2)

      assert {:ok, 2, "bb"} =
               Edit.replacement("aa", "a", "b", replace_all: true, max_occurrences: 2)
    end

    test "rejects malformed or duplicate options" do
      assert {:error, :invalid_options} = Edit.replacement("a", "a", "b", unknown: true)
      assert {:error, :invalid_options} = Edit.replacement("a", "a", "b", [:not_a_keyword])

      assert {:error, :invalid_options} =
               Edit.replacement("a", "a", "b", replace_all: true, replace_all: false)

      assert {:error, :invalid_options} =
               Edit.replacement("a", "a", "b", max_occurrences: 0)
    end

    test "preserves the legacy boolean caller contract" do
      assert {:ok, 2, "bb"} = Edit.replacement("aa", "a", "b", true)
      assert {:error, "multiple occurrences"} = Edit.replacement("aa", "a", "b", false)
      assert {:error, :not_found} = Edit.replacement("a", "", "b", false)
    end
  end

  test "Format delegates legacy replacement behavior to Edit" do
    assert {:ok, "new new", 2} =
             Format.perform_string_replacement("old old", "old", "new", replace_all: true)

    assert {:error, "multiple occurrences", 2} =
             Format.perform_string_replacement("old old", "old", "new")

    assert {:error, "string not found", 0} =
             Format.perform_string_replacement("old", "", "new")
  end
end
