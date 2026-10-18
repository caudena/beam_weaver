defmodule BeamWeaver.Filesystem.StoreEctoTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Store
  alias BeamWeaver.Memory
  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.PostgresRepo

  defmodule NotesAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat",
      responses: [
        FakeChatModel.tool_call("write_file", %{"file_path" => "/A-1001.md", "content" => "Full refund.\n"}),
        FakeChatModel.tool_call("edit_file", %{
          "file_path" => "/A-1001.md",
          "old_string" => "Full refund.",
          "new_string" => "Full refund approved."
        }),
        "Saved."
      ]

    filesystem BeamWeaver.Filesystem.Store.new(namespace: ["acme", "case_notes"])
  end

  setup do
    assert LivePostgres.available?()

    table = LivePostgres.unique_table("bw_filesystem_store")
    version = LivePostgres.migrate(adapters: [{:memory, table: table}])

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version)
    end)

    %{store: Memory.Ecto.new(repo: PostgresRepo, table: table), table: table}
  end

  test "an agent's file writes and edits are saved in Memory.Ecto", %{store: store} do
    assert {:ok, result} = NotesAgent.invoke(%{messages: ["Note the refund for A-1001."]}, store: store)

    assert result.messages |> Enum.filter(&(&1.role == :tool)) |> Enum.map(&BeamWeaver.Core.Message.text/1) ==
             ["Wrote /A-1001.md", "Edited /A-1001.md; replaced 1 occurrence(s)"]

    notes = Store.new(store: store, namespace: ["acme", "case_notes"])

    assert [%Filesystem.DownloadResult{content: "Full refund approved.\n", error: nil}] =
             Filesystem.download_files(notes, ["/A-1001.md"])

    assert %Filesystem.LsResult{entries: [%Filesystem.FileInfo{path: "/A-1001.md"}]} = Filesystem.ls(notes, "/")
  end

  test "uploads of text and binary files round-trip through Memory.Ecto", %{store: store} do
    files = Store.new(store: store, namespace: ["customers", "ada"])
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 255>>

    assert [%{path: "/AGENTS.md", error: nil}, %{path: "/logo.png", error: nil}] =
             Filesystem.upload_files(files, [{"/AGENTS.md", "- Prefers email.\n"}, {"/logo.png", png}])

    assert [%{content: "- Prefers email.\n", error: nil}, %{content: ^png, error: nil}] =
             Filesystem.download_files(files, ["/AGENTS.md", "/logo.png"])

    assert %Filesystem.WriteResult{error: nil} = Filesystem.write(files, "/logo.png", "now text")

    assert %Filesystem.ReadResult{file_data: %Filesystem.FileData{content: "now text", encoding: "utf-8"}} =
             Filesystem.read(files, "/logo.png")
  end

  test "a failed store write is reported, not lost", %{store: store, table: table} do
    files = Store.new(store: store, namespace: ["broken"])
    LivePostgres.drop_tables([table])

    assert %Filesystem.WriteResult{error: error} = Filesystem.write(files, "/a.md", "lost")
    assert is_binary(error)

    assert [%Filesystem.UploadResult{error: upload_error}] = Filesystem.upload_files(files, [{"/a.md", "lost"}])
    assert is_binary(upload_error)
  end
end
