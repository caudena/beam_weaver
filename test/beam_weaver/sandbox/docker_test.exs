defmodule BeamWeaver.Sandbox.DockerTest do
  use ExUnit.Case, async: false

  import BeamWeaver.TestSupport.Eventually

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.Permission
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

  test "canonical paths follow the container's symlinks, and permissions check them", %{sandbox: sandbox} do
    assert %Sandbox.ExecuteResult{exit_code: 0} =
             Sandbox.execute(
               sandbox,
               "mkdir -p secrets notes && echo TOPSECRET > secrets/key.txt && echo todo > notes/todo.md && " <>
                 "ln -s ../secrets/key.txt notes/key.txt && ln -s ../secrets notes/vault && " <>
                 "ln -s ../secrets/gone.txt notes/ghost && ln -s /etc notes/etc"
             )

    paths = [
      "/notes/key.txt",
      "/workspace/secrets/key.txt",
      "/notes/vault/new.txt",
      "/notes/./todo.md",
      "/notes/ghost",
      "/notes/etc/hostname",
      "/",
      "notes"
    ]

    assert Sandbox.canonical_paths(sandbox, paths) == [
             {:ok, "/secrets/key.txt"},
             {:ok, "/secrets/key.txt"},
             {:ok, "/secrets/new.txt"},
             {:ok, "/notes/todo.md"},
             {:ok, "/secrets/gone.txt"},
             {:error, "invalid_path"},
             {:ok, "/"},
             {:error, "invalid_path"}
           ]

    tools =
      [sandbox: sandbox]
      |> BeamWeaver.Filesystem.Sandbox.new()
      |> BeamWeaver.Tools.Filesystem.tools(permissions: [Permission.new(paths: ["/secrets/**"], mode: :deny)])

    read = Enum.find(tools, &(Tool.name(&1) == "read_file"))

    for path <- ["/notes/key.txt", "/workspace/secrets/key.txt", "/notes/vault/key.txt"] do
      assert {:ok, "Error: Permission denied reading " <> ^path} = Tool.invoke(read, %{"file_path" => path})
    end

    ls = Enum.find(tools, &(Tool.name(&1) == "ls"))
    assert {:ok, entries} = Tool.invoke(ls, %{"path" => "/notes"})
    assert entries |> JSON.decode!() |> Enum.map(& &1["path"]) == ["/notes/todo.md"]
  end

  test "download_files copies the file a symlink leads to in the container, never a host file", %{sandbox: sandbox} do
    # The same absolute path holds different text on the host and in the container.
    host_file = Path.join(System.tmp_dir!(), "beam_weaver_docker_host_#{System.unique_integer([:positive])}.txt")
    File.write!(host_file, "HOST FILE")
    on_exit(fn -> File.rm(host_file) end)

    assert %Sandbox.ExecuteResult{exit_code: 0} =
             Sandbox.execute(
               sandbox,
               "mkdir -p '#{Path.dirname(host_file)}' dir && echo container > '#{host_file}' && " <>
                 "ln -s '#{host_file}' link && ln -s /nowhere dangling"
             )

    assert [
             %Sandbox.DownloadResult{path: "/link", content: "container\n", error: nil},
             %Sandbox.DownloadResult{path: "/dangling", content: nil, error: dangling_error},
             %Sandbox.DownloadResult{path: "/dir", content: nil, error: "is_directory"}
           ] = Sandbox.download_files(sandbox, ["/link", "/dangling", "/dir"])

    assert is_binary(dangling_error)
  end

  test "execute timeouts stop the command and its background jobs inside the container",
       %{sandbox: sandbox} do
    command = "sleep 60 & echo $! > /tmp/job.pid; echo $$ > /tmp/shell.pid; wait"

    assert %Sandbox.ExecuteResult{exit_code: 124, error: "timeout"} =
             Sandbox.execute(sandbox, command, timeout: 1)

    still_running =
      "for f in /tmp/job.pid /tmp/shell.pid; do " <>
        "test -f $f && kill -0 \"$(cat $f)\" 2>/dev/null && echo $f; done; true"

    assert eventually(fn -> Sandbox.execute(sandbox, still_running).output == "" end)
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

  test "operations on a sandbox that isn't started start no container", %{docker_image: docker_image} do
    label = "io.beam_weaver.test=unstarted-#{System.unique_integer([:positive])}"
    [key, value] = String.split(label, "=")
    sandbox = Docker.new(image: docker_image, labels: %{key => value})

    on_exit(fn -> remove_labeled(label) end)

    assert %Sandbox.WriteResult{error: "container_not_started"} = Sandbox.write(sandbox, "/a.txt", "a")
    assert %Sandbox.ExecuteResult{error: "container_not_started"} = Sandbox.execute(sandbox, "echo hi")
    assert %Sandbox.ReadResult{error: "container_not_started"} = Sandbox.read(sandbox, "/a.txt")
    assert labeled_containers(label) == []
  end

  test "a started sandbox runs every operation in its one container", %{docker_image: docker_image} do
    label = "io.beam_weaver.test=reused-#{System.unique_integer([:positive])}"
    [key, value] = String.split(label, "=")
    sandbox = Docker.start!(Docker.new(image: docker_image, labels: %{key => value}))

    on_exit(fn -> Docker.stop(sandbox) end)

    assert %Sandbox.WriteResult{error: nil} = Sandbox.write(sandbox, "/a.txt", "one")
    assert %Sandbox.EditResult{error: nil} = Sandbox.edit(sandbox, "/a.txt", "one", "two")
    assert %Sandbox.ExecuteResult{output: "two"} = Sandbox.execute(sandbox, "cat a.txt")
    assert length(labeled_containers(label)) == 1
  end

  test "remove: true removes the container when the process that started it exits", %{
    docker_image: docker_image
  } do
    sandbox = Task.await(Task.async(fn -> Docker.start!(Docker.new(image: docker_image)) end), 60_000)

    on_exit(fn -> System.cmd("docker", ["rm", "-f", sandbox.container], stderr_to_stdout: true) end)

    assert eventually(fn -> match?({:error, _reason}, Docker.inspect_container(sandbox)) end, 15_000)
  end

  test "remove: false keeps the container after its owner exits, until stop/1", %{
    docker_image: docker_image
  } do
    sandbox =
      Task.await(Task.async(fn -> Docker.start!(Docker.new(image: docker_image, remove: false)) end), 60_000)

    on_exit(fn -> System.cmd("docker", ["rm", "-f", sandbox.container], stderr_to_stdout: true) end)

    Process.sleep(500)
    assert {:ok, %{"running" => true}} = Docker.inspect_container(sandbox)
    assert %Sandbox.ExecuteResult{exit_code: 0, output: "alive\n"} = Sandbox.execute(sandbox, "echo alive")

    assert :ok = Docker.stop(sandbox)
    assert {:error, _reason} = Docker.inspect_container(sandbox)
  end

  test "stop/1 removes a container whose owner is still running", %{docker_image: docker_image} do
    sandbox = Docker.start!(Docker.new(image: docker_image))
    reaper = sandbox.reaper

    assert is_pid(reaper)
    assert :ok = Docker.stop(sandbox)
    assert {:error, _reason} = Docker.inspect_container(sandbox)
    refute Process.alive?(reaper)
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

  defp labeled_containers(label) do
    {output, 0} = System.cmd("docker", ["ps", "-a", "-q", "--filter", "label=" <> label], stderr_to_stdout: true)
    String.split(output, "\n", trim: true)
  end

  defp remove_labeled(label) do
    for id <- labeled_containers(label), do: System.cmd("docker", ["rm", "-f", id], stderr_to_stdout: true)
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
