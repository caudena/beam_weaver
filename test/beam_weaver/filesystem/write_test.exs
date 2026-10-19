defmodule BeamWeaver.Filesystem.WriteTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Composite
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.LocalShell
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Filesystem.Store
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Memory

  setup do
    root = Path.join(System.tmp_dir!(), "beam_weaver_write_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "write replaces a file that exists, on every backend that stores what it writes", %{root: root} do
    for {name, backend} <- [
          {"Local", Local.new(root: Path.join(root, "local"))},
          {"LocalShell", LocalShell.new(root: Path.join(root, "local_shell"))},
          {"Sandbox.Local",
           Filesystem.Sandbox.new(sandbox: BeamWeaver.Sandbox.local(root: Path.join(root, "sandbox")))},
          {"Store", Store.new(store: Memory.ETS.new(), namespace: ["write"])},
          {"Composite route", Composite.new(routes: %{"/notes/" => Local.new(root: Path.join(root, "routed"))})}
        ] do
      assert %Filesystem.WriteResult{error: nil} = Filesystem.write(backend, "/notes/a.md", "first\n"), name

      assert %Filesystem.WriteResult{path: "/notes/a.md", error: nil} =
               Filesystem.write(backend, "/notes/a.md", "second\n"),
             name

      assert [%Filesystem.DownloadResult{content: "second\n", error: nil}] =
               Filesystem.download_files(backend, ["/notes/a.md"]),
             name
    end
  end

  test "a State write replaces the file, keeps when it was created and stores text as text" do
    created = "2026-01-01T00:00:00Z"

    old = %Filesystem.FileData{
      content: Base.encode64(<<0, 255>>),
      encoding: "base64",
      created_at: created,
      modified_at: created
    }

    assert %Filesystem.WriteResult{error: nil, files_update: %{"/logo.png" => written}} =
             Filesystem.write(State.new(), "/logo.png", "now text", state: %{files: %{"/logo.png" => old}})

    assert %Filesystem.FileData{content: "now text", encoding: "utf-8", created_at: ^created} = written
    assert written.modified_at != created
  end

  test "writing text over a binary file in a Store reads back as text" do
    store = Store.new(store: Memory.ETS.new(), namespace: ["binary"])
    assert [%{error: nil}] = Filesystem.upload_files(store, [{"/logo.png", <<0, 255>>}])

    assert %Filesystem.WriteResult{error: nil} = Filesystem.write(store, "/logo.png", "now text")

    assert %Filesystem.ReadResult{file_data: %Filesystem.FileData{content: "now text", encoding: "utf-8"}} =
             Filesystem.read(store, "/logo.png")
  end

  test "writing over a directory is still an error", %{root: root} do
    for backend <- [
          Local.new(root: Path.join(root, "local")),
          Filesystem.Sandbox.new(sandbox: BeamWeaver.Sandbox.local(root: Path.join(root, "sandbox")))
        ] do
      assert %Filesystem.WriteResult{error: nil} = Filesystem.write(backend, "/dir/a.md", "a")
      assert %Filesystem.WriteResult{error: "is_directory"} = Filesystem.write(backend, "/dir", "x")
    end
  end

  test "the write_file tool replaces a file that exists" do
    write = State.new() |> BeamWeaver.Tools.Filesystem.tools() |> Enum.find(&(Tool.name(&1) == "write_file"))

    assert {:ok, %Command{update: %{files: %{"/notes.md" => %Filesystem.FileData{content: "second"}}}}} =
             Tool.invoke(write, %{
               "file_path" => "/notes.md",
               "content" => "second",
               state: %{files: %{"/notes.md" => "first"}},
               tool_call_id: "call-write"
             })
  end
end
