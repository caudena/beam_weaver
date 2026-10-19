defmodule BeamWeaver.Filesystem.GlobRuleTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Composite
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.LocalShell
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Filesystem.Store
  alias BeamWeaver.Memory

  @files %{
    "/top.py" => "needle\n",
    "/src/util.py" => "needle\n",
    "/src/app/main.py" => "needle\n",
    "/docs/readme.md" => "needle\n"
  }

  # Each pattern, searched from `path`, and the files it finds: a pattern
  # without `/` matches the name at any depth, one with `/` the path from
  # `path`, and a leading `/` anchors it there.
  @cases [
    {"/", "*.py", ["/src/app/main.py", "/src/util.py", "/top.py"]},
    {"/", "**/*.py", ["/src/app/main.py", "/src/util.py", "/top.py"]},
    {"/", "/*.py", ["/top.py"]},
    {"/", "src/*.py", ["/src/util.py"]},
    {"/", "/src/*.py", ["/src/util.py"]},
    {"/", "src/**/*.py", ["/src/app/main.py", "/src/util.py"]},
    {"/", "main.py", ["/src/app/main.py"]},
    {"/src", "*.py", ["/src/app/main.py", "/src/util.py"]},
    {"/src", "/*.py", ["/src/util.py"]},
    {"/src", "app/*.py", ["/src/app/main.py"]}
  ]

  @classes_files %{
    "/src/a.py" => "needle\n",
    "/src/b.py" => "needle\n",
    "/src/c.py" => "needle\n",
    "/src/x.ts" => "needle\n",
    "/src/y.tsx" => "needle\n",
    "/src/lit[ab].py" => "needle\n"
  }

  # Classes, alternatives and escapes, searched from /src.
  @classes_cases [
    {"*.{ts,tsx}", ["/src/x.ts", "/src/y.tsx"]},
    {"/{a,c}.py", ["/src/a.py", "/src/c.py"]},
    {"[ab].py", ["/src/a.py", "/src/b.py"]},
    {"[a-b].py", ["/src/a.py", "/src/b.py"]},
    {"[!a].py", ["/src/b.py", "/src/c.py"]},
    {"[^a].py", ["/src/b.py", "/src/c.py"]},
    {"lit\\[ab\\].py", ["/src/lit[ab].py"]},
    {"lit[[]ab].py", ["/src/lit[ab].py"]}
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "beam_weaver_glob_rule_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "every backend follows the glob rule, for glob and for grep's glob filter", %{root: root} do
    for {name, backend, opts} <- backends(root), {path, pattern, expected} <- @cases do
      assert glob_paths(Filesystem.glob(backend, pattern, Keyword.put(opts, :path, path))) == expected,
             "#{name}: glob #{inspect(pattern)} in #{path}"

      grep_opts = opts |> Keyword.put(:path, path) |> Keyword.put(:glob, pattern)

      assert grep_paths(Filesystem.grep(backend, "needle", grep_opts)) == expected,
             "#{name}: grep with glob #{inspect(pattern)} in #{path}"
    end
  end

  test "every backend reads classes, alternatives and escapes the same way", %{root: root} do
    for {name, backend, opts} <- backends(root, @classes_files), {pattern, expected} <- @classes_cases do
      opts = Keyword.put(opts, :path, "/src")

      assert glob_paths(Filesystem.glob(backend, pattern, opts)) == expected, "#{name}: glob #{inspect(pattern)}"

      assert grep_paths(Filesystem.grep(backend, "needle", Keyword.put(opts, :glob, pattern))) == expected,
             "#{name}: grep with glob #{inspect(pattern)}"
    end
  end

  test "an unclosed class or alternative is an invalid pattern on every backend", %{root: root} do
    for {name, backend, opts} <- backends(root, @classes_files), pattern <- ["*.{ts", "[ab.py"] do
      assert %{error: "invalid_pattern"} = Filesystem.glob(backend, pattern, opts), "#{name}: glob #{inspect(pattern)}"

      assert %{error: "invalid_pattern"} = Filesystem.grep(backend, "needle", Keyword.put(opts, :glob, pattern)),
             "#{name}: grep with glob #{inspect(pattern)}"
    end
  end

  test "a search path that doesn't exist is file_not_found for glob, grep and ls", %{root: root} do
    for {name, backend, opts} <- backends(root) do
      missing = Keyword.put(opts, :path, "/nope")

      assert %{error: "file_not_found"} = Filesystem.glob(backend, "*.py", missing), "#{name}: glob"
      assert %{error: "file_not_found"} = Filesystem.grep(backend, "needle", missing), "#{name}: grep"
      assert %{error: "file_not_found"} = Filesystem.ls(backend, "/nope", opts), "#{name}: ls"

      # A folder that only holds files exists, and so does /.
      assert %{error: nil} = Filesystem.ls(backend, "/src", opts), "#{name}: ls /src"
      assert %{error: nil} = Filesystem.glob(backend, "*.py", Keyword.put(opts, :path, "/src/app")), "#{name}"
    end

    assert %{error: nil, entries: []} = Filesystem.ls(State.new(), "/", state: %{files: %{}})
    assert %{error: nil, matches: []} = Filesystem.glob(State.new(), "*.py", state: %{files: %{}})
  end

  test "grep with a file as its path searches that file", %{root: root} do
    for {name, backend, opts} <- backends(root) do
      assert grep_paths(Filesystem.grep(backend, "needle", Keyword.put(opts, :path, "/src/util.py"))) == [
               "/src/util.py"
             ],
             name
    end
  end

  test "grep with an empty glob searches every file", %{root: root} do
    for {name, backend, opts} <- backends(root) do
      assert grep_paths(Filesystem.grep(backend, "needle", Keyword.put(opts, :glob, ""))) ==
               @files |> Map.keys() |> Enum.sort(),
             name
    end
  end

  describe "Composite" do
    # The default backend holds /top.py and /docs/a.md, the route
    # /policies/refunds.md, /policies/old/2019.md and /policies/docs/x.md.
    setup %{root: root} do
      policies = Local.new(root: root)

      [_ | _] =
        Filesystem.upload_files(policies, [
          {"/refunds.md", "needle\n"},
          {"/old/2019.md", "needle\n"},
          {"/docs/x.md", "needle\n"}
        ])

      backend = Composite.new(default: State.new(), routes: %{"/policies/" => policies})
      opts = [state: %{files: %{"/top.py" => "needle\n", "/docs/a.md" => "needle\n"}}]
      %{backend: backend, opts: opts}
    end

    test "a pattern with / searched from / is relative to /, in the routes too", %{backend: backend, opts: opts} do
      for {pattern, expected} <- [
            {"*.md", ["/docs/a.md", "/policies/docs/x.md", "/policies/old/2019.md", "/policies/refunds.md"]},
            {"/*.md", []},
            {"/*.py", ["/top.py"]},
            {"policies/*.md", ["/policies/refunds.md"]},
            {"/policies/*.md", ["/policies/refunds.md"]},
            {"policies/**/*.md", ["/policies/docs/x.md", "/policies/old/2019.md", "/policies/refunds.md"]},
            {"docs/*.md", ["/docs/a.md"]},
            {"**/docs/*.md", ["/docs/a.md", "/policies/docs/x.md"]},
            {"*/refunds.md", ["/policies/refunds.md"]}
          ] do
        assert glob_paths(Filesystem.glob(backend, pattern, opts)) == expected, "glob #{inspect(pattern)}"

        assert grep_paths(Filesystem.grep(backend, "needle", Keyword.put(opts, :glob, pattern))) == expected,
               "grep with glob #{inspect(pattern)}"
      end
    end

    test "a pattern with / searched from a route is relative to the path searched", %{backend: backend, opts: opts} do
      for {pattern, expected} <- [
            {"*.md", ["/policies/docs/x.md", "/policies/old/2019.md", "/policies/refunds.md"]},
            {"/*.md", ["/policies/refunds.md"]},
            {"old/*.md", ["/policies/old/2019.md"]}
          ] do
        search_opts = Keyword.put(opts, :path, "/policies")
        assert glob_paths(Filesystem.glob(backend, pattern, search_opts)) == expected, "glob #{inspect(pattern)}"

        assert grep_paths(Filesystem.grep(backend, "needle", Keyword.put(search_opts, :glob, pattern))) == expected,
               "grep with glob #{inspect(pattern)}"
      end
    end
  end

  describe "Composite with a route below a folder of the default backend" do
    # The default backend holds /top.md and /workspace/readme.md, the route
    # /workspace/memories/notes/memo.md.
    setup %{root: root} do
      memories = Local.new(root: root)
      [_] = Filesystem.upload_files(memories, [{"/notes/memo.md", "needle\n"}])

      backend = Composite.new(default: State.new(), routes: %{"/workspace/memories/" => memories})
      opts = [state: %{files: %{"/top.md" => "needle\n", "/workspace/readme.md" => "needle\n"}}]
      %{backend: backend, opts: opts}
    end

    test "a search from a folder above the route searches the route too", %{backend: backend, opts: opts} do
      for {pattern, expected} <- [
            {"*.md", ["/workspace/memories/notes/memo.md", "/workspace/readme.md"]},
            {"/*.md", ["/workspace/readme.md"]},
            {"memories/**/*.md", ["/workspace/memories/notes/memo.md"]},
            {"*/notes/*.md", ["/workspace/memories/notes/memo.md"]}
          ] do
        search_opts = Keyword.put(opts, :path, "/workspace")
        assert glob_paths(Filesystem.glob(backend, pattern, search_opts)) == expected, "glob #{inspect(pattern)}"

        assert grep_paths(Filesystem.grep(backend, "needle", Keyword.put(search_opts, :glob, pattern))) == expected,
               "grep with glob #{inspect(pattern)}"
      end

      assert grep_paths(Filesystem.grep(backend, "needle", Keyword.put(opts, :path, "/workspace"))) ==
               ["/workspace/memories/notes/memo.md", "/workspace/readme.md"]
    end

    test "ls shows the route as a folder at each level above it", %{backend: backend, opts: opts} do
      assert ls_paths(Filesystem.ls(backend, "/", opts)) == [{"/top.md", false}, {"/workspace", true}]

      assert ls_paths(Filesystem.ls(backend, "/workspace", opts)) ==
               [{"/workspace/memories", true}, {"/workspace/readme.md", false}]
    end

    test "a folder that only leads to the route exists", %{backend: backend} do
      opts = [state: %{files: %{}}]

      assert ls_paths(Filesystem.ls(backend, "/workspace", opts)) == [{"/workspace/memories", true}]

      assert glob_paths(Filesystem.glob(backend, "*.md", Keyword.put(opts, :path, "/workspace"))) ==
               ["/workspace/memories/notes/memo.md"]

      assert %{error: "file_not_found"} = Filesystem.ls(backend, "/nope", opts)
      assert %{error: "file_not_found"} = Filesystem.glob(backend, "*.md", Keyword.put(opts, :path, "/nope"))
    end
  end

  defp ls_paths(%Filesystem.LsResult{error: nil, entries: entries}), do: Enum.map(entries, &{&1.path, &1.is_dir})
  defp ls_paths(result), do: result

  # Each backend with `files` in it, and the options to search it with.  # Each backend with `files` in it, and the options to search it with.
  defp backends(root, files \\ @files) do
    uploaded = [
      {"Local", Local.new(root: Path.join(root, "local"))},
      {"LocalShell", LocalShell.new(root: Path.join(root, "local_shell"))},
      {"Sandbox.Local", Filesystem.Sandbox.new(sandbox: BeamWeaver.Sandbox.local(root: Path.join(root, "sandbox")))},
      {"Store", Store.new(store: Memory.ETS.new(), namespace: ["glob_rule"])}
    ]

    for {name, backend} <- uploaded do
      assert Enum.all?(Filesystem.upload_files(backend, Enum.to_list(files)), &is_nil(&1.error))
      {name, backend, []}
    end
    |> Kernel.++([{"State", State.new(), [state: %{files: files}]}])
  end

  defp glob_paths(%Filesystem.GlobResult{error: nil, matches: matches}),
    do: matches |> Enum.reject(& &1.is_dir) |> Enum.map(& &1.path)

  defp glob_paths(result), do: result

  defp grep_paths(%Filesystem.GrepResult{error: nil, matches: matches}),
    do: matches |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort()

  defp grep_paths(result), do: result
end
