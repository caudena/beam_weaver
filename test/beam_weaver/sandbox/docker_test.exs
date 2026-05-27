defmodule BeamWeaver.Sandbox.DockerTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Sandbox
  alias BeamWeaver.Sandbox.Docker

  @default_image "python:3.11-slim"
  @configured_image BeamWeaver.Config.get([:test, :docker_image])
  @requested_image @configured_image || @default_image

  @docker_available match?(
                      {_version, 0},
                      System.cmd("docker", ["version", "--format", "{{.Server.Version}}"], stderr_to_stdout: true)
                    )

  @image_available @docker_available and
                     match?(
                       {_inspect, 0},
                       System.cmd("docker", ["image", "inspect", @requested_image], stderr_to_stdout: true)
                     )

  @run_docker? @docker_available and
                 (@image_available or
                    @configured_image not in [nil, ""])

  if @run_docker? do
    setup do
      sandbox = Docker.new(image: @requested_image) |> Docker.start!()

      on_exit(fn ->
        if sandbox.container do
          System.cmd("docker", ["rm", "-f", sandbox.container], stderr_to_stdout: true)
        end
      end)

      %{sandbox: sandbox}
    end

    test "supports virtual filesystem operations and execution inside Docker", %{sandbox: sandbox} do
      path = "/work/hello.txt"

      assert %Sandbox.WriteResult{path: ^path, error: nil} =
               Sandbox.write(sandbox, path, "hello\nneedle\nold")

      assert %Sandbox.ReadResult{file_data: %{"content" => "hello\nneedle\nold"}} =
               Sandbox.read(sandbox, path)

      assert %Sandbox.ListResult{entries: entries, error: nil} = Sandbox.ls(sandbox, "/work")
      assert %{"path" => ^path, "is_dir" => false} = Enum.find(entries, &(&1["path"] == path))

      assert %Sandbox.GlobResult{matches: matches, error: nil} =
               Sandbox.glob(sandbox, "*.txt", path: "/work")

      assert %{"path" => ^path, "is_dir" => false} = Enum.find(matches, &(&1["path"] == path))

      assert %Sandbox.GrepResult{matches: [%{"path" => ^path, "line" => 2, "text" => "needle"}]} =
               Sandbox.grep(sandbox, "needle", path: "/work", glob: "*.txt")

      assert %Sandbox.EditResult{path: ^path, occurrences: 1, error: nil} =
               Sandbox.edit(sandbox, path, "old", "new")

      assert %Sandbox.ExecuteResult{exit_code: 0, output: "hello\nneedle\nnew", truncated: false} =
               Sandbox.execute(sandbox, "cat work/hello.txt")

      assert [%Sandbox.DownloadResult{path: ^path, content: "hello\nneedle\nnew", error: nil}] =
               Sandbox.download_files(sandbox, [path])
    end
  else
    @skip_reason (if @docker_available do
                    "Docker image #{@requested_image} is not available locally; set BEAM_WEAVER_DOCKER_TEST_IMAGE to run with a pullable image"
                  else
                    "Docker daemon is not available"
                  end)

    @tag skip: @skip_reason
    test "supports virtual filesystem operations and execution inside Docker" do
      :ok
    end
  end
end
