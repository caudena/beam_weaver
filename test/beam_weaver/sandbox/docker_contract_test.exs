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

  test "owned cleanup rejects an empty or malformed identity before Docker I/O" do
    sandbox = Docker.new(container: "not-inspected")

    assert {:error, "invalid_docker_container_identity"} = Docker.stop_owned(sandbox, %{})

    assert {:error, "invalid_docker_container_identity"} =
             Docker.stop_owned(sandbox, %{[] => "invalid"})
  end
end
