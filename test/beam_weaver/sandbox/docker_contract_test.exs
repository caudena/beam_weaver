defmodule BeamWeaver.Sandbox.DockerContractTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Sandbox
  alias BeamWeaver.Sandbox.Docker

  test "durable exec requires the caller to retain an already-started sandbox" do
    assert {:error, "container_not_started"} = Docker.start_exec(Docker.new(), "printf ok")
  end

  test "operations on a sandbox that isn't started return an error and start nothing" do
    sandbox = Docker.new()

    assert %Sandbox.ExecuteResult{exit_code: nil, error: "container_not_started"} =
             Sandbox.execute(sandbox, "echo hi")

    assert %Sandbox.WriteResult{path: "/a.txt", error: "container_not_started"} =
             Sandbox.write(sandbox, "/a.txt", "a")

    assert %Sandbox.ReadResult{error: "container_not_started"} = Sandbox.read(sandbox, "/a.txt")

    assert %Sandbox.EditResult{error: "container_not_started"} =
             Sandbox.edit(sandbox, "/a.txt", "a", "b")

    assert %Sandbox.ListResult{error: "container_not_started"} = Sandbox.ls(sandbox, "/")
    assert %Sandbox.GlobResult{error: "container_not_started"} = Sandbox.glob(sandbox, "*")
    assert %Sandbox.GrepResult{error: "container_not_started"} = Sandbox.grep(sandbox, "a")

    assert [%Sandbox.UploadResult{error: "container_not_started"}] =
             Sandbox.upload_files(sandbox, [{"/a.txt", "a"}])

    assert [%Sandbox.DownloadResult{error: "container_not_started"}] =
             Sandbox.download_files(sandbox, ["/a.txt"])
  end

  test "a relative or invalid path is an error result for every file operation, before Docker I/O" do
    sandbox = Docker.new(container: "not-inspected")
    relative = "sandbox paths must be absolute virtual paths"

    assert %Sandbox.WriteResult{error: ^relative} = Sandbox.write(sandbox, "notes.md", "a")
    assert %Sandbox.ReadResult{error: ^relative} = Sandbox.read(sandbox, "notes.md")
    assert %Sandbox.EditResult{error: ^relative} = Sandbox.edit(sandbox, "notes.md", "a", "b")
    assert %Sandbox.ListResult{error: ^relative} = Sandbox.ls(sandbox, "notes")
    assert %Sandbox.GlobResult{error: ^relative} = Sandbox.glob(sandbox, "*", path: "notes")
    assert %Sandbox.GrepResult{error: ^relative} = Sandbox.grep(sandbox, "a", path: "notes")

    assert %Sandbox.ReadResult{error: "invalid sandbox path"} = Sandbox.read(sandbox, "/a/../b.md")
    assert %Sandbox.ListResult{error: "invalid sandbox path"} = Sandbox.ls(sandbox, "/a/../b")

    not_utf8 = <<"/notes", 0xFF, ".md">>
    assert %Sandbox.WriteResult{error: "invalid_path"} = Sandbox.write(sandbox, not_utf8, "a")
    assert %Sandbox.ReadResult{error: "invalid_path"} = Sandbox.read(sandbox, not_utf8)
    assert %Sandbox.EditResult{error: "invalid_path"} = Sandbox.edit(sandbox, not_utf8, "a", "b")
    assert %Sandbox.ListResult{error: "invalid_path"} = Sandbox.ls(sandbox, not_utf8)
    assert %Sandbox.GlobResult{error: "invalid_path"} = Sandbox.glob(sandbox, "*", path: not_utf8)
    assert %Sandbox.GrepResult{error: "invalid_path"} = Sandbox.grep(sandbox, "a", path: not_utf8)
  end

  test "owned cleanup rejects an empty or malformed identity before Docker I/O" do
    sandbox = Docker.new(container: "not-inspected")

    assert {:error, "invalid_docker_container_identity"} = Docker.stop_owned(sandbox, %{})

    assert {:error, "invalid_docker_container_identity"} =
             Docker.stop_owned(sandbox, %{[] => "invalid"})
  end
end
