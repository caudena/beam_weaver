defmodule BeamWeaver.Filesystem.StateStoreTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Composite
  alias BeamWeaver.Filesystem.Permission
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Filesystem.Store
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Memory
  alias BeamWeaver.Tools.Filesystem, as: FilesystemTools

  defmodule FailingStore do
    @moduledoc false
    # A memory store whose writes fail and whose reads fail when `reads: :fail`.
    @behaviour BeamWeaver.Memory.Store

    defstruct reads: :ok

    @impl true
    def put(_store, _namespace, _key, _value, _opts), do: {:error, Error.new(:memory_error, "memory adapter error")}

    @impl true
    def search(%__MODULE__{reads: :fail}, _namespace, _opts), do: {:error, Error.new(:memory_error, "database down")}
    def search(_store, _namespace, _opts), do: []

    @impl true
    def get(_store, _namespace, _key), do: :error
    @impl true
    def delete(_store, _namespace, _key), do: :ok
    @impl true
    def list_namespaces(_store, _opts), do: []
    @impl true
    def batch(_store, _ops), do: []
  end

  @files %{
    "/top.md" => "top",
    "/docs/guide.md" => "guide",
    "/docs/deep/notes.md" => "notes",
    "/docs/readme.txt" => "readme"
  }

  describe "glob" do
    test "**/ matches files at the top level as well as in subdirectories" do
      assert glob_paths(State.glob(State.new(), "**/*.md", state: %{files: @files})) ==
               ["/docs/deep/notes.md", "/docs/guide.md", "/top.md"]

      assert glob_paths(State.glob(State.new(), "**/*.md", path: "/docs", state: %{files: @files})) ==
               ["/docs/deep/notes.md", "/docs/guide.md"]

      assert glob_paths(State.glob(State.new(), "docs/**/*.md", state: %{files: @files})) ==
               ["/docs/deep/notes.md", "/docs/guide.md"]

      store = Store.new(store: Memory.ETS.new(), namespace: ["glob"])
      assert Enum.all?(Filesystem.upload_files(store, Enum.to_list(@files)), &is_nil(&1.error))

      assert glob_paths(Filesystem.glob(store, "**/*.md")) == ["/docs/deep/notes.md", "/docs/guide.md", "/top.md"]
    end

    test "a permission on /dir/**/name also covers /dir/name" do
      rules = [Permission.new(paths: ["/workspace/**/secret.md"], mode: :deny)]

      refute Permission.allowed?(rules, :read, "/workspace/secret.md")
      refute Permission.allowed?(rules, :read, "/workspace/a/b/secret.md")
      assert Permission.allowed?(rules, :read, "/workspace/public.md")
    end
  end

  describe "State" do
    test "upload_files explains how State files change instead of reporting success" do
      assert [%Filesystem.UploadResult{path: "/a.md", error: error}] =
               State.upload_files(State.new(), [{"/a.md", "text"}], state: %{})

      assert error =~ "live in the thread's state"
      assert error =~ "update_state/4"
    end

    test "a State route keeps its files under the route's prefix" do
      backend = Composite.new(default: State.new(), routes: %{"/scratch/" => State.new()})
      write = backend |> FilesystemTools.tools() |> Enum.find(&(Tool.name(&1) == "write_file"))

      assert {:ok, %Command{update: %{files: written}}} =
               Tool.invoke(write, %{
                 "file_path" => "/scratch/draft.md",
                 "content" => "draft",
                 state: %{files: %{"/notes.md" => "default file"}},
                 tool_call_id: "call-write"
               })

      assert %Filesystem.FileData{content: "draft"} = written["/scratch/draft.md"]
      refute Map.has_key?(written, "/draft.md")

      # The write's update holds only the file it wrote; the files channel
      # merges it into the state's files.
      opts = [state: %{files: Map.merge(%{"/notes.md" => "default file"}, written)}]

      assert %Filesystem.ReadResult{file_data: %Filesystem.FileData{content: "draft"}} =
               Filesystem.read(backend, "/scratch/draft.md", opts)

      assert %Filesystem.ReadResult{error: "file_not_found"} = Filesystem.read(backend, "/scratch/notes.md", opts)
      assert %Filesystem.LsResult{entries: [%{path: "/scratch/draft.md"}]} = Filesystem.ls(backend, "/scratch", opts)

      assert backend |> Filesystem.ls("/", opts) |> Map.fetch!(:entries) |> Enum.map(& &1.path) ==
               ["/notes.md", "/scratch"]

      assert glob_paths(Filesystem.glob(backend, "**/*.md", opts)) == ["/notes.md", "/scratch/draft.md"]

      assert %Filesystem.GrepResult{matches: [%{path: "/scratch/draft.md", line: 1}]} =
               Filesystem.grep(backend, "draft", opts)

      assert %Filesystem.WriteResult{error: nil, files_update: %{"/scratch/draft.md" => %{content: "again"}}} =
               Filesystem.write(backend, "/scratch/draft.md", "again", opts)
    end

    test "a State route in a nested composite keeps the full path" do
      inner = Composite.new(default: State.new(), routes: %{"/b/" => State.new()})
      backend = Composite.new(routes: %{"/a/" => inner})

      assert %Filesystem.WriteResult{path: "/a/b/x.md", files_update: files} =
               Filesystem.write(backend, "/a/b/x.md", "x", state: %{})

      assert Map.keys(files) == ["/a/b/x.md"]

      assert %Filesystem.WriteResult{path: "/a/x.md", files_update: written} =
               Filesystem.write(backend, "/a/x.md", "y", state: %{files: files})

      assert %Filesystem.EditResult{path: "/a/x.md", files_update: edited} =
               Filesystem.edit(backend, "/a/x.md", "y", "z", state: %{files: Map.merge(files, written)})

      assert Map.keys(edited) == ["/a/x.md"]
    end

    test "an agent writing under a State route saves the file at the path it asked for" do
      model =
        BeamWeaver.Models.init_chat_model!("fake:chat",
          responses: [
            BeamWeaver.Models.FakeChatModel.tool_call("write_file", %{"file_path" => "/scratch/x.md", "content" => "x"}),
            "Saved."
          ]
        )

      {:ok, agent} =
        BeamWeaver.Agent.build(
          model: model,
          filesystem: Composite.new(default: State.new(), routes: %{"/scratch/" => State.new()})
        )

      assert {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["save a scratch note"]})
      assert Map.keys(result.files) == ["/scratch/x.md"]
    end
  end

  describe "Store" do
    test "saves each file as a JSON-safe map" do
      store = Memory.ETS.new()
      backend = Store.new(store: store, namespace: ["json"])

      assert %Filesystem.WriteResult{error: nil, files_update: nil} = Filesystem.write(backend, "/notes/a.md", "hello")
      assert [%{error: nil}] = Filesystem.upload_files(backend, [{"/b.bin", <<0, 255>>}])

      assert {:ok, %{value: %{"content" => "hello", "encoding" => "utf-8"} = value}} =
               Memory.get(store, ["json"], "notes/a.md")

      assert JSON.encode!(value) =~ "hello"
      assert {:ok, %{value: %{"encoding" => "base64"}}} = Memory.get(store, ["json"], "b.bin")

      assert %Filesystem.EditResult{error: nil, occurrences: 1} =
               Filesystem.edit(backend, "/notes/a.md", "hello", "bye")

      assert {:ok, %{value: %{"content" => "bye"}}} = Memory.get(store, ["json"], "notes/a.md")
    end

    test "reports a failed store write in the result instead of success" do
      backend = Store.new(store: %FailingStore{}, namespace: ["fail"])

      assert %Filesystem.WriteResult{error: "memory adapter error"} = Filesystem.write(backend, "/a.md", "lost")

      assert [%Filesystem.UploadResult{path: "/a.md", error: "memory adapter error"}] =
               Filesystem.upload_files(backend, [{"/a.md", "lost"}])

      failing_reads = Store.new(store: %FailingStore{reads: :fail}, namespace: ["fail"])

      assert %Filesystem.ReadResult{error: "database down"} = Filesystem.read(failing_reads, "/a.md")
      assert %Filesystem.LsResult{error: "database down"} = Filesystem.ls(failing_reads, "/")

      assert [%Filesystem.DownloadResult{path: "/a.md", error: "database down"}] =
               Filesystem.download_files(failing_reads, ["/a.md"])
    end

    test "reports a missing store instead of dropping writes" do
      backend = Store.new(namespace: ["nowhere"])

      assert %Filesystem.WriteResult{error: "missing_store"} = Filesystem.write(backend, "/a.md", "lost")
      assert [%Filesystem.UploadResult{error: "missing_store"}] = Filesystem.upload_files(backend, [{"/a.md", "x"}])
    end

    test "sees only its own namespace, not nested ones" do
      store = Memory.ETS.new()
      parent = Store.new(store: store, namespace: ["acme"])
      child = Store.new(store: store, namespace: ["acme", "policies"])

      assert [%{error: nil}] = Filesystem.upload_files(parent, [{"/team.md", "team"}])

      assert [%{error: nil}, %{error: nil}] =
               Filesystem.upload_files(child, [{"/team.md", "policy"}, {"/refunds.md", "refunds"}])

      assert %Filesystem.ReadResult{file_data: %{content: "team"}} = Filesystem.read(parent, "/team.md")
      assert glob_paths(Filesystem.glob(parent, "**/*.md")) == ["/team.md"]
    end

    test "a Store route under a composite uses paths relative to its namespace" do
      store = Memory.ETS.new()
      backend = Composite.new(routes: %{"/policies/" => Store.new(store: store, namespace: ["policies"])})

      assert %Filesystem.WriteResult{path: "/policies/refunds.md", error: nil} =
               Filesystem.write(backend, "/policies/refunds.md", "30 days", state: %{})

      assert {:ok, %{value: %{"content" => "30 days"}}} = Memory.get(store, ["policies"], "refunds.md")
    end
  end

  test "reading an empty file gives the reminder a file on disk gives" do
    root = Path.join(System.tmp_dir!(), "beam_weaver_empty_read_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    local = Filesystem.Local.new(root: root)
    File.write!(Path.join(root, "empty.md"), "")
    assert %Filesystem.ReadResult{file_data: %{content: reminder}} = Filesystem.read(local, "/empty.md")
    assert reminder =~ "empty contents"

    store = Store.new(store: Memory.ETS.new(), namespace: ["empty"])
    assert [%{error: nil}] = Filesystem.upload_files(store, [{"/empty.md", ""}])

    assert %Filesystem.ReadResult{file_data: %{content: ^reminder}} =
             Filesystem.read(State.new(), "/empty.md", state: %{files: %{"/empty.md" => ""}})

    assert %Filesystem.ReadResult{file_data: %{content: ^reminder}} = Filesystem.read(store, "/empty.md")
  end

  describe "Composite" do
    test "ls and search at / return the error of a backend that fails" do
      opts = [path: "/", state: %{files: %{"/scratch/a.md" => "x"}}]
      failing_default = Composite.new(default: Store.new(), routes: %{"/scratch/" => State.new()})

      assert %Filesystem.LsResult{error: "missing_store"} = Filesystem.ls(failing_default, "/", opts)
      assert %Filesystem.GlobResult{error: "missing_store"} = Filesystem.glob(failing_default, "**/*", opts)
      assert %Filesystem.GrepResult{error: "missing_store"} = Filesystem.grep(failing_default, "x", opts)

      failing_route = Composite.new(default: State.new(), routes: %{"/memories/" => Store.new()})

      assert %Filesystem.GlobResult{error: "missing_store"} = Filesystem.glob(failing_route, "**/*", opts)
      assert %Filesystem.GrepResult{error: "missing_store"} = Filesystem.grep(failing_route, "x", opts)
    end
  end

  defp glob_paths(%Filesystem.GlobResult{error: nil, matches: matches}), do: Enum.map(matches, & &1.path)
end
