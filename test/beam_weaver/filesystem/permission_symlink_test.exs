defmodule BeamWeaver.Filesystem.PermissionSymlinkTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Composite
  alias BeamWeaver.Filesystem.FileDataUtils
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.LocalShell
  alias BeamWeaver.Filesystem.Permission
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Filesystem.Store
  alias BeamWeaver.Sandbox

  @deny_secrets [Permission.new(paths: ["/secrets/**"], mode: :deny)]

  # A backend whose canonical_paths/3 returns the wrong number of results.
  defmodule BrokenCanonical do
    @moduledoc false
    use BeamWeaver.Filesystem

    alias BeamWeaver.Filesystem

    defstruct []

    @impl true
    def canonical_paths(_backend, _paths, _opts), do: []
    @impl true
    def ls(_backend, _path, _opts), do: %Filesystem.LsResult{entries: []}
    @impl true
    def read(_backend, _path, _opts), do: %Filesystem.ReadResult{error: "file_not_found"}
    @impl true
    def write(_backend, path, _content, _opts), do: %Filesystem.WriteResult{path: path}
    @impl true
    def edit(_backend, path, _old, _new, _opts), do: %Filesystem.EditResult{path: path, occurrences: 1}
    @impl true
    def glob(_backend, _pattern, _opts), do: %Filesystem.GlobResult{matches: []}
    @impl true
    def grep(_backend, _pattern, _opts), do: %Filesystem.GrepResult{matches: []}
    @impl true
    def upload_files(_backend, files, _opts), do: Enum.map(files, &%Filesystem.UploadResult{path: elem(&1, 0)})
    @impl true
    def download_files(_backend, paths, _opts), do: Enum.map(paths, &%Filesystem.DownloadResult{path: &1})
  end

  # Every link below leads into `/secrets`, which the rules deny:
  #
  #   /notes/key.txt   -> ../secrets/key.txt      a file
  #   /notes/again.txt -> key.txt                 a link to that link
  #   /notes/vault     -> <root>/secrets          a folder, by absolute path
  #   /b/key.txt       -> ../secrets/key.txt
  #   /a/hop           -> ../b                    so /a/hop/key.txt takes two links
  #   /notes/detour    -> ../a/hop/../secrets/key.txt
  #                                               the `..` climbs from /b, so this is
  #                                               /secrets/key.txt; read as text it
  #                                               would be the decoy /a/secrets/key.txt
  #   /notes/ghost     -> ../secrets/missing.txt  a link to a file that doesn't exist
  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "beam_weaver_permission_links_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    root = Path.join(tmp_dir, "root")

    for dir <- ["secrets", "notes", "docs", "a/secrets", "b"], do: File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join(root, "secrets/key.txt"), "TOPSECRET\n")
    File.write!(Path.join(root, "notes/todo.md"), "TOKEN notes\n")
    File.write!(Path.join(root, "docs/guide.md"), "TOKEN docs\n")
    File.write!(Path.join(root, "a/secrets/key.txt"), "decoy\n")

    File.ln_s!("../secrets/key.txt", Path.join(root, "notes/key.txt"))
    File.ln_s!("key.txt", Path.join(root, "notes/again.txt"))
    File.ln_s!(Path.join(root, "secrets"), Path.join(root, "notes/vault"))
    File.ln_s!("../secrets/key.txt", Path.join(root, "b/key.txt"))
    File.ln_s!("../b", Path.join(root, "a/hop"))
    File.ln_s!("../a/hop/../secrets/key.txt", Path.join(root, "notes/detour"))
    File.ln_s!("../secrets/missing.txt", Path.join(root, "notes/ghost"))

    %{root: root}
  end

  @linked_secrets [
    "/notes/key.txt",
    "/notes/again.txt",
    "/notes/vault/key.txt",
    "/b/key.txt",
    "/a/hop/key.txt",
    "/notes/detour"
  ]

  for kind <- [:local, :local_shell, :sandbox] do
    @kind kind

    describe "#{kind} backend" do
      test "canonical_paths follows the links inside the directory", %{root: root} do
        backend = backend(@kind, root)

        assert Filesystem.canonical_paths(backend, @linked_secrets) == List.duplicate({:ok, "/secrets/key.txt"}, 6)

        assert Filesystem.canonical_paths(backend, ["/notes/vault", "/a/hop", "/notes/./todo.md", "/", "/new/dir/a.md"]) ==
                 [{:ok, "/secrets"}, {:ok, "/b"}, {:ok, "/notes/todo.md"}, {:ok, "/"}, {:ok, "/new/dir/a.md"}]

        # A new file in a linked folder is the file in the folder it links to.
        assert Filesystem.canonical_paths(backend, ["/notes/vault/new.txt", "/a/hop/new.txt"]) ==
                 [{:ok, "/secrets/new.txt"}, {:ok, "/b/new.txt"}]

        assert [{:error, _dangling}, {:error, _relative}] =
                 Filesystem.canonical_paths(backend, ["/notes/ghost", "notes"])
      end

      test "read_file refuses a denied file through a symlink", %{root: root} do
        read = file_tool(backend(@kind, root), "read_file", @deny_secrets)

        for path <- @linked_secrets do
          assert {:ok, "Error: Permission denied reading " <> ^path} = Tool.invoke(read, %{"file_path" => path})
        end

        assert {:ok, "TOKEN notes" <> _rest} = Tool.invoke(read, %{"file_path" => "/notes/todo.md"})
      end

      test "ls, glob and grep leave out what leads to a denied file", %{root: root} do
        tools = tools(backend(@kind, root), @deny_secrets)

        assert paths(invoke(tools, "ls", %{"path" => "/notes"})) == ["/notes/todo.md"]
        assert invoke(tools, "ls", %{"path" => "/notes/vault"}) == "Error: Permission denied reading /notes/vault"

        assert paths(invoke(tools, "glob", %{"pattern" => "**/*", "path" => "/"})) ==
                 ["/a", "/a/hop", "/a/secrets", "/a/secrets/key.txt", "/b", "/docs", "/docs/guide.md", "/notes"] ++
                   ["/notes/todo.md"]

        assert paths(invoke(tools, "glob", %{"pattern" => "*", "path" => "/a/hop"})) == []

        assert invoke(tools, "grep", %{"pattern" => "TOPSECRET", "path" => "/"}) == "[]"
        assert invoke(tools, "grep", %{"pattern" => "TOPSECRET", "path" => "/notes"}) == "[]"
        assert invoke(tools, "grep", %{"pattern" => "TOPSECRET", "path" => "/a/hop"}) == "[]"

        assert paths(invoke(tools, "grep", %{"pattern" => "TOKEN", "path" => "/"})) == [
                 "/docs/guide.md",
                 "/notes/todo.md"
               ]
      end

      test "write_file and edit_file can't change a denied file through a symlink", %{root: root} do
        tools = tools(backend(@kind, root), @deny_secrets)

        assert invoke(tools, "write_file", %{"file_path" => "/notes/vault/new.txt", "content" => "x"}) ==
                 "Error: Permission denied writing /notes/vault/new.txt"

        assert invoke(tools, "write_file", %{"file_path" => "/notes/ghost", "content" => "x"}) ==
                 "Error: Permission denied writing /notes/ghost"

        assert invoke(tools, "edit_file", %{
                 "file_path" => "/notes/key.txt",
                 "old_string" => "TOPSECRET",
                 "new_string" => "CHANGED"
               }) == "Error: Permission denied editing /notes/key.txt"

        assert File.ls!(Path.join(root, "secrets")) == ["key.txt"]
        assert File.read!(Path.join(root, "secrets/key.txt")) == "TOPSECRET\n"

        # New files in allowed folders, and in folders that don't exist yet, still work.
        for path <- ["/notes/new.md", "/fresh/dir/new.md", "/a/hop/new.md"] do
          assert %{content: "Wrote " <> ^path} = invoke(tools, "write_file", %{"file_path" => path, "content" => "ok"})
        end

        assert File.read!(Path.join(root, "b/new.md")) == "ok"
      end
    end
  end

  test "allow rules must allow the file a symlink leads to", %{root: root} do
    File.mkdir_p!(Path.join(root, "public"))
    File.write!(Path.join(root, "public/faq.md"), "FAQ\n")
    File.ln_s!("faq.md", Path.join(root, "public/help.md"))
    File.ln_s!("../secrets/key.txt", Path.join(root, "public/key.txt"))
    public_only = [Permission.new(paths: ["/public/**"]), Permission.new(paths: ["/**"], mode: :deny)]
    read = file_tool(Local.new(root: root), "read_file", public_only)

    assert {:ok, "FAQ" <> _rest} = Tool.invoke(read, %{"file_path" => "/public/help.md"})

    assert {:ok, "Error: Permission denied reading /public/key.txt"} =
             Tool.invoke(read, %{"file_path" => "/public/key.txt"})
  end

  test "allowed?/5 and filter_paths/5 check the path and the file it leads to", %{root: root} do
    backend = Local.new(root: root)

    assert Permission.allowed?(@deny_secrets, :read, "/notes/key.txt")
    refute Permission.allowed?(@deny_secrets, :read, "/notes/key.txt", backend)
    assert Permission.allowed?(@deny_secrets, :read, "/notes/todo.md", backend)
    refute Permission.allowed?(@deny_secrets, :read, "/notes/ghost", backend)

    # Without rules for the operation, nothing is resolved or denied.
    read_rules = [Permission.new(operations: [:read], paths: ["/secrets/**"], mode: :deny)]
    assert Permission.allowed?(read_rules, :write, "/notes/key.txt", backend)
    assert Permission.allowed?([], :read, "/notes/ghost", backend)

    paths = ["/notes/todo.md", "/notes/key.txt", "/docs/guide.md", "/notes/todo.md", "/secrets/key.txt"]

    assert Permission.filter_paths(@deny_secrets, :read, paths, backend) ==
             ["/notes/todo.md", "/docs/guide.md", "/notes/todo.md"]
  end

  test "a backend that can't resolve a path is denied when rules cover the operation" do
    backend = %__MODULE__.BrokenCanonical{}

    refute Permission.allowed?(@deny_secrets, :read, "/notes/todo.md", backend)
    assert Permission.allowed?([], :read, "/notes/todo.md", backend)
  end

  test "State and Store paths have no links: their canonical path is the clean path" do
    store = BeamWeaver.Memory.ETS.new()
    paths = ["/notes/./a.md", "//b.md", "/notes/", "notes/a.md", "/../a.md", "~/a.md"]
    clean = [{:ok, "/notes/a.md"}, {:ok, "/b.md"}, {:ok, "/notes"}] ++ List.duplicate({:error, "invalid_path"}, 3)

    assert Filesystem.canonical_paths(State.new(), paths) == clean
    assert Filesystem.canonical_paths(Store.new(store: store), paths) == clean

    state = %{files: %{"/notes/key.txt" => FileDataUtils.file_data("not a link")}}
    read = file_tool(State.new(), "read_file", @deny_secrets)
    assert {:ok, "not a link"} = Tool.invoke(read, %{"file_path" => "/notes/key.txt", "state" => state})
  end

  test "a Composite resolves a path in its route's backend and keeps the route's prefix", %{root: root} do
    composite = Composite.new(default: State.new(), routes: %{"/ws/" => Local.new(root: root)})

    assert Filesystem.canonical_paths(composite, [
             "/ws/notes/key.txt",
             "/ws/a/hop",
             "/ws",
             "/ws/notes/new.md",
             "/x/./a.md"
           ]) ==
             [
               {:ok, "/ws/secrets/key.txt"},
               {:ok, "/ws/b"},
               {:ok, "/ws"},
               {:ok, "/ws/notes/new.md"},
               {:ok, "/x/a.md"}
             ]

    tools = tools(composite, [Permission.new(paths: ["/ws/secrets/**"], mode: :deny)])

    assert invoke(tools, "read_file", %{"file_path" => "/ws/notes/key.txt"}) ==
             "Error: Permission denied reading /ws/notes/key.txt"

    assert paths(invoke(tools, "ls", %{"path" => "/ws/notes"})) == ["/ws/notes/todo.md"]
    assert invoke(tools, "grep", %{"pattern" => "TOPSECRET", "path" => "/"}) == "[]"

    # Of the files named key.txt, only the decoy, which is no link, is left.
    glob = paths(invoke(tools, "glob", %{"pattern" => "**/*", "path" => "/"}))
    assert "/ws/notes/todo.md" in glob
    assert Enum.filter(glob, &String.ends_with?(&1, "key.txt")) == ["/ws/a/secrets/key.txt"]

    # The default backend's paths resolve there, without a prefix.
    local_default = Composite.new(default: Local.new(root: root), routes: %{"/mem/" => State.new()})

    assert Filesystem.canonical_paths(local_default, ["/notes/key.txt", "/mem/./a.md", "/mem"]) ==
             [{:ok, "/secrets/key.txt"}, {:ok, "/mem/a.md"}, {:ok, "/mem"}]
  end

  test "a local sandbox resolves its paths like a directory", %{root: root} do
    sandbox = Sandbox.local(root: root)

    assert Sandbox.canonical_paths(sandbox, ["/notes/key.txt", "/notes/vault/new.txt", "/docs/../x", root]) ==
             [{:ok, "/secrets/key.txt"}, {:ok, "/secrets/new.txt"}, {:error, "invalid_path"}, {:ok, root}]
  end

  defp backend(:local, root), do: Local.new(root: root)
  defp backend(:local_shell, root), do: LocalShell.new(root: root)
  defp backend(:sandbox, root), do: Filesystem.Sandbox.new(sandbox: Sandbox.local(root: root))

  defp tools(backend, permissions), do: BeamWeaver.Tools.Filesystem.tools(backend, permissions: permissions)

  defp file_tool(backend, name, permissions), do: backend |> tools(permissions) |> Enum.find(&(Tool.name(&1) == name))

  defp invoke(tools, name, input) do
    {:ok, result} = tools |> Enum.find(&(Tool.name(&1) == name)) |> Tool.invoke(input)
    result
  end

  defp paths(json) when is_binary(json), do: json |> JSON.decode!() |> Enum.map(& &1["path"]) |> Enum.uniq()
end
