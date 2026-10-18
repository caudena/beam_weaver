defmodule BeamWeaver.TestSupport.Conformance.FilesystemFixtures do
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Sandbox

  # A wrapper backend that passes every call on to the backend it wraps. With
  # `resolve: :nothing`, its canonical_paths/3 resolves no path instead.
  defmodule Wrapper do
    @moduledoc false
    use BeamWeaver.Filesystem

    alias BeamWeaver.Filesystem

    defstruct [:inner, resolve: :inner]

    @impl true
    def ls(fs, path, opts), do: Filesystem.ls(fs.inner, path, opts)
    @impl true
    def read(fs, path, opts), do: Filesystem.read(fs.inner, path, opts)
    @impl true
    def write(fs, path, content, opts), do: Filesystem.write(fs.inner, path, content, opts)
    @impl true
    def edit(fs, path, old, new, opts), do: Filesystem.edit(fs.inner, path, old, new, opts)
    @impl true
    def glob(fs, pattern, opts), do: Filesystem.glob(fs.inner, pattern, opts)
    @impl true
    def grep(fs, pattern, opts), do: Filesystem.grep(fs.inner, pattern, opts)
    @impl true
    def upload_files(fs, files, opts), do: Filesystem.upload_files(fs.inner, files, opts)
    @impl true
    def download_files(fs, paths, opts), do: Filesystem.download_files(fs.inner, paths, opts)

    @impl true
    def canonical_paths(%{resolve: :nothing}, paths, _opts), do: Enum.map(paths, fn _path -> {:error, "unresolved"} end)
    def canonical_paths(fs, paths, opts), do: Filesystem.canonical_paths(fs.inner, paths, opts)
  end

  # The same wrapper without canonical_paths/3, so the rules can't see where
  # the inner backend's links lead.
  defmodule WrapperWithoutCanonicalPaths do
    @moduledoc false
    use BeamWeaver.Filesystem

    alias BeamWeaver.Filesystem

    defstruct [:inner]

    @impl true
    def ls(fs, path, opts), do: Filesystem.ls(fs.inner, path, opts)
    @impl true
    def read(fs, path, opts), do: Filesystem.read(fs.inner, path, opts)
    @impl true
    def write(fs, path, content, opts), do: Filesystem.write(fs.inner, path, content, opts)
    @impl true
    def edit(fs, path, old, new, opts), do: Filesystem.edit(fs.inner, path, old, new, opts)
    @impl true
    def glob(fs, pattern, opts), do: Filesystem.glob(fs.inner, pattern, opts)
    @impl true
    def grep(fs, pattern, opts), do: Filesystem.grep(fs.inner, pattern, opts)
    @impl true
    def upload_files(fs, files, opts), do: Filesystem.upload_files(fs.inner, files, opts)
    @impl true
    def download_files(fs, paths, opts), do: Filesystem.download_files(fs.inner, paths, opts)
  end

  def local, do: in_new_dir(&Filesystem.Local.new(root: &1))
  def local_shell, do: in_new_dir(&Filesystem.LocalShell.new(root: &1))
  def sandbox, do: in_new_dir(&Filesystem.Sandbox.new(sandbox: Sandbox.local(root: &1)))
  def wrapper, do: in_new_dir(&%Wrapper{inner: Filesystem.Local.new(root: &1)})
  def wrapper_resolving_nothing, do: in_new_dir(&%Wrapper{inner: Filesystem.Local.new(root: &1), resolve: :nothing})

  def wrapper_without_canonical_paths,
    do: in_new_dir(&%WrapperWithoutCanonicalPaths{inner: Filesystem.Local.new(root: &1)})

  def state, do: Filesystem.State.new()

  # A directory mounted at `/ws/`, next to files in the thread's state.
  def composite do
    root = new_dir()
    routes = %{"/ws/" => Filesystem.Local.new(root: root)}
    {Filesystem.Composite.new(default: Filesystem.State.new(), routes: routes), linker(root, "/ws")}
  end

  defp in_new_dir(build) do
    root = new_dir()
    {build.(root), linker(root, "/")}
  end

  # A directory for one test, removed when the test ends.
  defp new_dir do
    root = Path.join(System.tmp_dir!(), "beam_weaver_fs_conformance_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    root
  end

  # Makes the backend path `link` lead to `target`, for a backend that keeps
  # the paths under `mount` in `root`.
  defp linker(root, mount) do
    disk = &Path.join(root, Path.relative_to(&1, mount))
    fn link, target -> File.ln_s!(disk.(target), disk.(link)) end
  end
end

defmodule BeamWeaver.TestSupport.Conformance.FilesystemLocalTest do
  use BeamWeaver.TestSupport.Conformance.FilesystemCase,
    build: &BeamWeaver.TestSupport.Conformance.FilesystemFixtures.local/0,
    capabilities: [:symlinks]
end

defmodule BeamWeaver.TestSupport.Conformance.FilesystemLocalShellTest do
  use BeamWeaver.TestSupport.Conformance.FilesystemCase,
    build: &BeamWeaver.TestSupport.Conformance.FilesystemFixtures.local_shell/0,
    capabilities: [:symlinks]
end

defmodule BeamWeaver.TestSupport.Conformance.FilesystemCompositeTest do
  use BeamWeaver.TestSupport.Conformance.FilesystemCase,
    build: &BeamWeaver.TestSupport.Conformance.FilesystemFixtures.composite/0,
    capabilities: [:symlinks],
    fixtures: %{dir: "/ws"}
end

defmodule BeamWeaver.TestSupport.Conformance.FilesystemSandboxTest do
  use BeamWeaver.TestSupport.Conformance.FilesystemCase,
    build: &BeamWeaver.TestSupport.Conformance.FilesystemFixtures.sandbox/0,
    capabilities: [:symlinks]
end

defmodule BeamWeaver.TestSupport.Conformance.FilesystemWrapperTest do
  use BeamWeaver.TestSupport.Conformance.FilesystemCase,
    build: &BeamWeaver.TestSupport.Conformance.FilesystemFixtures.wrapper/0,
    capabilities: [:symlinks]
end

defmodule BeamWeaver.TestSupport.Conformance.FilesystemStateTest do
  use BeamWeaver.TestSupport.Conformance.FilesystemCase,
    build: &BeamWeaver.TestSupport.Conformance.FilesystemFixtures.state/0
end

defmodule BeamWeaver.TestSupport.Conformance.FilesystemCaseTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Filesystem.Conformance
  alias BeamWeaver.TestSupport.Conformance.FilesystemCase
  alias BeamWeaver.TestSupport.Conformance.FilesystemFixtures
  alias BeamWeaver.TestSupport.Conformance.Subject

  test "fails for a wrapper that doesn't pass canonical_paths/3 on" do
    subject =
      Subject.new(
        [build: &FilesystemFixtures.wrapper_without_canonical_paths/0, capabilities: [:symlinks]],
        :filesystem
      )

    error = assert_raise ExUnit.AssertionError, fn -> FilesystemCase.assert_links_denied(subject) end
    assert error.message =~ "permission rules don't see through the backend's symlinks"
    assert error.message =~ "* read_file /notes/key.txt wasn't denied: it returned the text of a file a rule denies"
  end

  test "names each way the links reach the denied files" do
    {backend, make_link} = FilesystemFixtures.wrapper_without_canonical_paths()

    assert Conformance.check_symlinks(backend, make_link) ==
             {:error,
              [
                ~s(canonical_paths/3 returned {:ok, "/notes/key.txt"} for /notes/key.txt instead of {:ok, "/secrets/key.txt"}),
                ~s(canonical_paths/3 returned {:ok, "/notes/vault"} for /notes/vault instead of {:ok, "/secrets"}),
                ~s(canonical_paths/3 returned {:ok, "/notes/vault/key.txt"} for /notes/vault/key.txt instead of {:ok, "/secrets/key.txt"}),
                ~s(canonical_paths/3 returned {:ok, "/notes/vault/new.txt"} for /notes/vault/new.txt instead of {:ok, "/secrets/new.txt"}),
                "read_file /notes/key.txt wasn't denied: it returned the text of a file a rule denies",
                "read_file /notes/vault/key.txt wasn't denied: it returned the text of a file a rule denies",
                "ls /notes listed /notes/key.txt, which leads into /secrets",
                "ls /notes listed /notes/vault, which leads into /secrets",
                "ls /notes/vault wasn't denied: it listed /notes/vault/key.txt",
                "glob **/* in / returned /notes/key.txt, which leads into /secrets",
                "glob **/* in / returned /notes/vault, which leads into /secrets",
                "glob **/* in / returned /notes/vault/key.txt, which leads into /secrets",
                "grep in / found the text of /secrets/key.txt, which a rule denies, in /notes/key.txt, /notes/vault/key.txt",
                "grep in /notes found the text of /secrets/key.txt, which a rule denies, in /notes/key.txt, /notes/vault/key.txt",
                "write_file /notes/vault/new.txt wrote /secrets/new.txt, which a rule denies",
                "edit_file /notes/key.txt changed /secrets/key.txt, which a rule denies",
                "write_file /notes/key.txt replaced /secrets/key.txt, which a rule denies"
              ]}
  end

  test "fails for a backend that denies every path, links or not" do
    {backend, make_link} = FilesystemFixtures.wrapper_resolving_nothing()

    assert {:error, problems} = Conformance.check_symlinks(backend, make_link)

    assert Enum.filter(problems, &(&1 =~ "which no rule denies")) == [
             ~s(read_file /notes/todo.md, which no rule denies, returned "Error: Permission denied reading /notes/todo.md"),
             "ls /notes left out /notes/todo.md, which no rule denies",
             "glob **/* in / left out /notes/todo.md, which no rule denies",
             ~s(write_file /notes/new.md, which no rule denies, returned "Error: Permission denied writing /notes/new.md")
           ]
  end

  test "refuses to pass when make_link makes no link" do
    {backend, _make_link} = FilesystemFixtures.local()

    assert {:error, ["reading /notes/key.txt doesn't return /secrets/key.txt: make_link made no link there" <> _rest]} =
             Conformance.check_symlinks(backend, fn _link, _target -> :ok end)
  end
end
