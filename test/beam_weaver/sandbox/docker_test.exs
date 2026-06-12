defmodule BeamWeaver.Sandbox.DockerTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Sandbox
  alias BeamWeaver.Sandbox.Docker

  @moduletag :docker

  @default_image "python:3.11-slim"

  setup_all do
    configured_image = System.get_env("BEAM_WEAVER_DOCKER_TEST_IMAGE")
    requested_image = configured_image || @default_image

    cond do
      not docker_available?() ->
        flunk("Docker daemon is not available")

      configured_image in [nil, ""] and not image_available?(requested_image) ->
        flunk(
          "Docker image #{requested_image} is not available locally; set BEAM_WEAVER_DOCKER_TEST_IMAGE to run with a pullable image"
        )

      true ->
        {:ok, docker_image: requested_image}
    end
  end

  setup %{docker_image: docker_image} do
    sandbox = Docker.new(image: docker_image) |> Docker.start!()

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

  defp docker_available? do
    match?(
      {_version, 0},
      System.cmd("docker", ["version", "--format", "{{.Server.Version}}"], stderr_to_stdout: true)
    )
  end

  defp image_available?(image) do
    match?(
      {_inspect, 0},
      System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true)
    )
  end
end
