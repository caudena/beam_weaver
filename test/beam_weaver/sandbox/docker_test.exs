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

  test "mounts application-owned directories with explicit container restrictions", %{
    docker_image: docker_image
  } do
    root = Path.join(System.tmp_dir!(), "beam-weaver-docker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "input.txt"), "mounted")

    sandbox =
      Docker.new(
        image: docker_image,
        root: "/workspace",
        mounts: [%{source: root, target: "/workspace", read_only: false}],
        read_only: true,
        cap_drop: ["ALL"],
        security_opts: ["no-new-privileges"],
        tmpfs: ["/tmp:rw,noexec,nosuid,size=16m"]
      )
      |> Docker.start!()

    on_exit(fn ->
      Docker.stop(sandbox)
      File.rm_rf(root)
    end)

    assert %Sandbox.ExecuteResult{exit_code: 0, output: "mounted"} =
             Sandbox.execute(sandbox, "cat input.txt")
  end

  test "binds container cleanup to immutable labels", %{docker_image: docker_image} do
    name = "beam-weaver-owned-#{System.unique_integer([:positive])}"
    labels = %{"io.beam_weaver.test" => name}

    sandbox =
      Docker.new(image: docker_image, name: name, labels: labels)
      |> Docker.start!()

    on_exit(fn ->
      System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true)
    end)

    assert {:ok,
            %{
              "id" => identity,
              "name" => ^name,
              "labels" => ^labels,
              "running" => true
            }} = Docker.inspect_container(sandbox)

    assert byte_size(identity) == 64

    assert {:error, "docker_container_identity_mismatch"} =
             Docker.stop_owned(sandbox, %{"io.beam_weaver.test" => "different"})

    assert {:ok, %{"running" => true}} = Docker.inspect_container(sandbox)
    assert :ok = Docker.stop_owned(sandbox, labels)
    assert {:error, _reason} = Docker.inspect_container(sandbox)
  end

  test "streams an inspectable exec and proves stop before reporting terminal", %{
    sandbox: sandbox
  } do
    assert {:ok, handle} =
             Docker.start_exec(sandbox, "printf first; sleep 30; printf never")

    assert eventually(fn ->
             match?(
               {:ok, %{output: "first", observed_bytes: 5, running: true}},
               Docker.read_exec(sandbox, handle, 0, 64)
             )
           end)

    assert :ok = Docker.stop_exec(sandbox, handle, 250)

    assert {:ok, terminal} = Docker.read_exec(sandbox, handle, 0, 64)
    assert terminal.output == "first"
    assert terminal.running == false
    assert terminal.status in [137, 143]

    assert {:error, "docker_exec_identity_mismatch"} =
             Docker.read_exec(sandbox, %{handle | container: "other"}, 0, 64)
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

  defp eventually(fun, remaining \\ 100)

  defp eventually(fun, remaining) when remaining > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, remaining - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
