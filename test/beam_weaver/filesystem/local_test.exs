defmodule BeamWeaver.Filesystem.LocalTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.LocalShell

  # `tmp_dir/root` is the agent's directory; `tmp_dir/outside.txt` is a file
  # next to it that the agent must not see. The symlinks the tests add can
  # point back up, so the directory lives outside the project and is removed.
  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "beam_weaver_local_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    root = Path.join(tmp_dir, "root")
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "docs/guide.md"), "TOKEN inside\n")
    File.write!(Path.join(tmp_dir, "outside.txt"), "TOKEN outside\n")
    %{root: root, tmp_dir: tmp_dir}
  end

  for module <- [Local, LocalShell] do
    @module module

    test "#{inspect(module)} glob and grep refuse patterns that climb out of the directory", %{root: root} do
      backend = @module.new(root: root)

      for pattern <- ["../*", "..\\/*", ".\\./*", "docs/../../*", "~/*"] do
        assert %Filesystem.GlobResult{matches: nil, error: "invalid_pattern"} =
                 Filesystem.glob(backend, pattern, path: "/")

        assert %Filesystem.GrepResult{matches: nil, error: "invalid_pattern"} =
                 Filesystem.grep(backend, "TOKEN", path: "/", glob: pattern)
      end
    end

    test "#{inspect(module)} glob, grep and ls leave out symlinks that point outside the directory",
         %{root: root, tmp_dir: tmp_dir} do
      File.ln_s!(Path.join(tmp_dir, "outside.txt"), Path.join(root, "outside_link.txt"))
      # Points at the directory that holds the root, so `/up/root/...` leads back in.
      File.ln_s!(tmp_dir, Path.join(root, "up"))
      File.ln_s!(Path.join(root, "docs"), Path.join(root, "alias"))
      backend = @module.new(root: root)

      assert %Filesystem.GlobResult{matches: matches} = Filesystem.glob(backend, "**/*", path: "/")
      assert Enum.map(matches, & &1.path) == ["/alias", "/alias/guide.md", "/docs", "/docs/guide.md"]

      assert %Filesystem.GrepResult{matches: matches} = Filesystem.grep(backend, "TOKEN", path: "/")

      assert Enum.map(matches, &{&1.path, &1.text}) == [
               {"/alias/guide.md", "TOKEN inside"},
               {"/docs/guide.md", "TOKEN inside"}
             ]

      assert %Filesystem.LsResult{entries: entries} = Filesystem.ls(backend, "/")
      assert Enum.map(entries, & &1.path) == ["/alias", "/docs"]

      assert %Filesystem.ReadResult{error: "invalid_path"} = Filesystem.read(backend, "/up/root/docs/guide.md")
      assert %Filesystem.ReadResult{error: "invalid_path"} = Filesystem.read(backend, "/outside_link.txt")
    end

    test "#{inspect(module)} follows a `..` after a symlink from where the link leads, as the OS does",
         %{root: root} do
      File.mkdir_p!(Path.join(root, "x"))
      File.mkdir_p!(Path.join(root, "notes"))
      # /x/up is the root and /x/docs is /docs, so a `..` after them climbs
      # from there: /notes/escape leads out of the root to outside.txt, and
      # /notes/guide to /docs/guide.md. Read as text, both paths name files
      # under /x instead, and /x/outside.txt exists.
      File.ln_s!("..", Path.join(root, "x/up"))
      File.ln_s!("../docs", Path.join(root, "x/docs"))
      File.write!(Path.join(root, "x/outside.txt"), "decoy\n")
      File.ln_s!("../x/up/../outside.txt", Path.join(root, "notes/escape"))
      File.ln_s!("../x/docs/../docs/guide.md", Path.join(root, "notes/guide"))
      backend = @module.new(root: root)

      assert %Filesystem.ReadResult{error: "invalid_path"} = Filesystem.read(backend, "/notes/escape")
      assert %Filesystem.ReadResult{file_data: %{content: "TOKEN inside"}} = Filesystem.read(backend, "/notes/guide")

      assert Filesystem.canonical_paths(backend, ["/notes/escape", "/notes/guide"]) ==
               [{:error, "invalid_path"}, {:ok, "/docs/guide.md"}]

      assert %Filesystem.LsResult{entries: entries} = Filesystem.ls(backend, "/notes")
      assert Enum.map(entries, & &1.path) == ["/notes/guide"]
    end
  end

  test "the grep tool can't read files next to the directory", %{root: root} do
    grep = backend_tool(Local.new(root: root), "grep")

    assert {:ok, "Error: invalid_pattern"} = Tool.invoke(grep, %{"pattern" => "TOKEN", "glob" => "../*.txt"})

    assert {:ok, ~s([{"line":1,"path":"/docs/guide.md","text":"TOKEN inside"}])} =
             Tool.invoke(grep, %{"pattern" => "TOKEN"})
  end

  test "glob and grep work in a directory whose name has glob characters", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "notes [draft] {v2}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "todo.md"), "TOKEN\n")
    backend = Local.new(root: root)

    assert %Filesystem.GlobResult{matches: [%Filesystem.FileInfo{path: "/todo.md", size: 6}]} =
             Filesystem.glob(backend, "*.md", path: "/")

    assert %Filesystem.GrepResult{matches: [%Filesystem.GrepMatch{path: "/todo.md", line: 1}]} =
             Filesystem.grep(backend, "TOKEN", path: "/")
  end

  test "a malformed glob pattern is an error result", %{root: root} do
    assert %Filesystem.GlobResult{error: "invalid_pattern"} = Filesystem.glob(Local.new(root: root), "{a,b", path: "/")
  end

  defp backend_tool(backend, name),
    do: backend |> BeamWeaver.Tools.Filesystem.tools() |> Enum.find(&(Tool.name(&1) == name))
end
