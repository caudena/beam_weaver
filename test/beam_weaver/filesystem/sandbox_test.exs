defmodule BeamWeaver.Filesystem.SandboxTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Sandbox

  defmodule MetadataSandbox do
    use BeamWeaver.Sandbox

    alias BeamWeaver.Sandbox

    defstruct [:id]

    @impl true
    def execute(%__MODULE__{}, command, _opts) do
      %Sandbox.ExecuteResult{
        exit_code: 0,
        output: command,
        metadata: %{provider_id: "remote", sandbox_id: "sbx-1", command_id: "inner-command"}
      }
    end

    @impl true
    def write(_sandbox, path, _content, _opts), do: %Sandbox.WriteResult{path: path}

    @impl true
    def read(_sandbox, _path, _opts), do: %Sandbox.ReadResult{file_data: %{"encoding" => "utf-8", "content" => "ok"}}

    @impl true
    def edit(_sandbox, path, _old, _new, _opts), do: %Sandbox.EditResult{path: path, occurrences: 1}

    @impl true
    def ls(_sandbox, _path, _opts), do: %Sandbox.ListResult{entries: [%{"path" => "/file", "is_dir" => false}]}

    @impl true
    def glob(_sandbox, _pattern, _opts), do: %Sandbox.GlobResult{matches: [%{"path" => "/file", "is_dir" => false}]}

    @impl true
    def grep(_sandbox, _pattern, _opts),
      do: %Sandbox.GrepResult{matches: [%{"path" => "/file", "line" => 1, "text" => "ok"}]}

    @impl true
    def upload_files(_sandbox, files, _opts),
      do: Enum.map(files, fn {path, _content} -> %Sandbox.UploadResult{path: path} end)

    @impl true
    def download_files(_sandbox, paths, _opts), do: Enum.map(paths, &%Sandbox.DownloadResult{path: &1, content: "ok"})
  end

  test "execution metadata survives filesystem sandbox adapter mapping" do
    backend = Filesystem.Sandbox.new(sandbox: %MetadataSandbox{id: "sandbox-id"})

    assert Executable.id(backend) == "sandbox-id"

    assert %Executable.ExecuteResult{exit_code: 0, output: "echo ok", metadata: metadata} =
             Executable.execute(backend, "echo ok", command_id: "outer-command")

    assert metadata.provider_id == "remote"
    assert metadata.sandbox_id == "sbx-1"
    assert metadata.command_id == "inner-command"

    assert %Filesystem.LsResult{entries: [%Filesystem.FileInfo{path: "/file", is_dir: false}]} =
             Filesystem.ls(backend, "/")

    assert %Filesystem.ReadResult{file_data: %Filesystem.FileData{content: "ok"}} =
             Filesystem.read(backend, "/file")

    assert %Filesystem.GrepResult{matches: [%Filesystem.GrepMatch{path: "/file", line: 1, text: "ok"}]} =
             Filesystem.grep(backend, "ok")
  end
end
