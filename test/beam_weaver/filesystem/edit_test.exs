defmodule BeamWeaver.Filesystem.EditTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Filesystem
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
      assert {:error, "old_string must not be empty"} = Edit.replacement("a", "", "b", false)
      assert {:error, :not_found} = Edit.replacement("content", "missing", "new", false)
      assert {:error, :invalid_options} = Edit.replacement("a", "a", "b", nil)
    end
  end

  test "every backend rejects an empty old_string and leaves the file as it was" do
    root = Path.join(System.tmp_dir!(), "beam_weaver_edit_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    stored = [
      Filesystem.Store.new(store: BeamWeaver.Memory.ETS.new()),
      Filesystem.Local.new(root: Path.join(root, "local")),
      Filesystem.Sandbox.new(sandbox: BeamWeaver.Sandbox.local(root: Path.join(root, "sandbox")))
    ]

    for backend <- stored, do: assert([%{error: nil}] = Filesystem.upload_files(backend, [{"/a.md", "text"}]))
    in_state = {Filesystem.State.new(), [state: %{files: %{"/a.md" => "text"}}]}

    for {backend, opts} <- [in_state | Enum.map(stored, &{&1, []})] do
      assert %Filesystem.EditResult{error: "old_string must not be empty"} =
               Filesystem.edit(backend, "/a.md", "", "more ", opts)

      assert %Filesystem.ReadResult{file_data: %{content: "text"}} = Filesystem.read(backend, "/a.md", opts)
    end
  end
end
