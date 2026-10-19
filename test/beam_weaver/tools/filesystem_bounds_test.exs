defmodule BeamWeaver.Tools.FilesystemBoundsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Tools.Filesystem, as: FilesystemTools

  @moduletag :tmp_dir

  defp invoke(backend \\ State.new(), name, args, files) do
    tool = backend |> FilesystemTools.tools() |> Enum.find(&(Tool.name(&1) == name))
    Tool.invoke(tool, Map.put(args, :state, %{files: files}))
  end

  describe "ls, glob and grep over many files" do
    setup do
      %{files: for(i <- 1..20_000, into: %{}, do: {"/data/file_#{i}.txt", "needle #{i}\n"})}
    end

    test "stop at whole entries within 80,000 characters and say how to narrow the search", %{files: files} do
      for {name, args, hint} <- [
            {"ls", %{"path" => "/data"}, "List a more specific path"},
            {"glob", %{"pattern" => "**/*.txt"}, "Narrow the search with a more specific path or pattern."},
            {"grep", %{"pattern" => "needle"}, "Narrow the search with a more specific path, pattern or glob."}
          ] do
        assert {:ok, result} = invoke(name, args, files)
        assert String.length(result) <= 80_000

        assert [json, note] = String.split(result, "\n\n", parts: 2)
        shown = json |> JSON.decode!() |> length()

        assert shown in 1..19_999
        assert note =~ "Results truncated: showing the first #{shown} of 20000 results."
        assert note =~ hint
      end
    end
  end

  test "a result within the limit is the plain JSON list" do
    assert {:ok, json} = invoke("glob", %{"pattern" => "*.txt", "path" => "/data"}, %{"/data/a.txt" => "needle\n"})
    assert [%{"path" => "/data/a.txt"}] = JSON.decode!(json)
  end

  describe "read_file" do
    setup do
      %{files: %{"/short.md" => "a\nb\nc\n", "/gap.md" => "a\n\nb\n", "/blank.md" => ""}}
    end

    test "rejects a negative offset and a limit below 1", %{files: files} do
      for args <- [%{"offset" => -2}, %{"limit" => -3}, %{"limit" => 0}] do
        assert {:error, %Error{type: :invalid_input}} =
                 invoke("read_file", Map.put(args, "file_path", "/short.md"), files)
      end
    end

    test "an offset past the end of the file is an error that gives its length", %{files: files} do
      assert {:ok, "Error: offset 50 is past the end of /short.md (3 lines)"} =
               invoke("read_file", %{"file_path" => "/short.md", "offset" => 50}, files)

      assert {:ok, "Error: offset 3 is past the end of /short.md (3 lines)"} =
               invoke("read_file", %{"file_path" => "/short.md", "offset" => 3}, files)

      assert {:ok, "c"} = invoke("read_file", %{"file_path" => "/short.md", "offset" => 2}, files)
    end

    test "an empty line and an empty file are no error", %{files: files} do
      assert {:ok, "\n\n[Showing line 2. The file continues: read again with offset 2.]"} =
               invoke("read_file", %{"file_path" => "/gap.md", "offset" => 1, "limit" => 1}, files)

      for offset <- [0, 4] do
        assert {:ok, content} = invoke("read_file", %{"file_path" => "/blank.md", "offset" => offset}, files)
        refute content =~ "Error"
      end
    end

    test "an offset past the end is an error on a directory too", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "one.md"), "only line")

      assert {:ok, "Error: offset 5 is past the end of /one.md (1 line)"} =
               invoke(Local.new(root: dir), "read_file", %{"file_path" => "/one.md", "offset" => 5}, %{})
    end
  end
end
