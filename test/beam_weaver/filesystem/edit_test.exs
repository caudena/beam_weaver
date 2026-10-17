defmodule BeamWeaver.Filesystem.EditTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Filesystem.Edit

  describe "replacement/4" do
    test "replaces one exact byte sequence by default" do
      assert {:ok, 1, "before new after"} =
               Edit.replacement("before old after", "old", "new", false)
    end

    test "replace_all replaces every non-overlapping occurrence" do
      assert {:ok, 3, "xxx"} =
               Edit.replacement("aaaaaa", "aa", "x", true)
    end

    test "supports arbitrary binary content" do
      assert {:ok, 1, <<0, 9, 255>>} =
               Edit.replacement(<<0, 1, 255>>, <<1>>, <<9>>, false)
    end

    test "preserves the legacy boolean caller contract" do
      assert {:ok, 2, "bb"} = Edit.replacement("aa", "a", "b", true)
      assert {:error, "multiple occurrences"} = Edit.replacement("aa", "a", "b", false)
      assert {:error, :not_found} = Edit.replacement("a", "", "b", false)
      assert {:error, :not_found} = Edit.replacement("content", "missing", "new", false)
      assert {:error, :invalid_options} = Edit.replacement("a", "a", "b", nil)
    end
  end
end
