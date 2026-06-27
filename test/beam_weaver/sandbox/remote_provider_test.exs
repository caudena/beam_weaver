defmodule BeamWeaver.Sandbox.RemoteProviderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Sandbox

  defmodule FakeRemoteSandbox do
    use BeamWeaver.Sandbox

    alias BeamWeaver.Sandbox

    defstruct [:provider_id, :sandbox_id, mode: :ok]

    @impl true
    def execute(%__MODULE__{mode: :timeout} = sandbox, _command, _opts) do
      %Sandbox.ExecuteResult{
        exit_code: 124,
        output: "",
        error: "timeout",
        metadata: %{
          provider_id: sandbox.provider_id,
          sandbox_id: sandbox.sandbox_id,
          kill_attempted: true,
          retryable: true,
          raw_status: "running"
        }
      }
    end

    def execute(%__MODULE__{mode: :output_fetch_failure} = sandbox, _command, _opts) do
      %Sandbox.ExecuteResult{
        exit_code: 42,
        output: "",
        error: "output_unavailable",
        metadata: %{
          provider_id: sandbox.provider_id,
          sandbox_id: sandbox.sandbox_id,
          output_unavailable: true,
          raw_status: "finished"
        }
      }
    end

    def execute(%__MODULE__{} = sandbox, command, _opts) do
      %Sandbox.ExecuteResult{
        exit_code: 0,
        output: "ok:#{command}",
        metadata: %{
          provider_id: sandbox.provider_id,
          sandbox_id: sandbox.sandbox_id,
          raw_status: "finished",
          api_key: "sk-secret"
        }
      }
    end

    @impl true
    def write(_sandbox, path, _content, _opts), do: %Sandbox.WriteResult{path: path}

    @impl true
    def read(_sandbox, _path, _opts), do: %Sandbox.ReadResult{file_data: %{"encoding" => "utf-8", "content" => ""}}

    @impl true
    def edit(_sandbox, path, _old, _new, _opts), do: %Sandbox.EditResult{path: path, occurrences: 1}

    @impl true
    def ls(_sandbox, _path, _opts), do: %Sandbox.ListResult{entries: []}

    @impl true
    def glob(_sandbox, _pattern, _opts), do: %Sandbox.GlobResult{matches: []}

    @impl true
    def grep(_sandbox, _pattern, _opts), do: %Sandbox.GrepResult{matches: []}

    @impl true
    def upload_files(_sandbox, files, _opts),
      do: Enum.map(files, fn {path, _content} -> %Sandbox.UploadResult{path: path} end)

    @impl true
    def download_files(_sandbox, paths, _opts), do: Enum.map(paths, &%Sandbox.DownloadResult{path: &1, content: ""})
  end

  test "remote sandbox timeout records kill attempt and emits native telemetry" do
    parent = self()
    ref = make_ref()
    attach_id = "beam-weaver-sandbox-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      attach_id,
      [
        [:beam_weaver, :sandbox, :execute, :start],
        [:beam_weaver, :sandbox, :execute, :timeout]
      ],
      &__MODULE__.handle_telemetry/4,
      {parent, ref}
    )

    on_exit(fn -> :telemetry.detach(attach_id) end)

    sandbox = %FakeRemoteSandbox{provider_id: "remote", sandbox_id: "sbx-1", mode: :timeout}

    assert %Sandbox.ExecuteResult{exit_code: 124, error: "timeout", metadata: metadata} =
             Sandbox.execute(sandbox, "sleep 60", command_id: "cmd-timeout", timeout: 1)

    assert metadata.kill_attempted == true
    assert metadata.retryable == true
    assert metadata.command_id == "cmd-timeout"

    assert_receive {^ref, [:beam_weaver, :sandbox, :execute, :start], %{system_time: _},
                    %{command_id: "cmd-timeout", command: "sleep 60"}}

    assert_receive {^ref, [:beam_weaver, :sandbox, :execute, :timeout], %{duration: _},
                    %{metadata: %{kill_attempted: true, retryable: true, raw_status: "running"}}}
  end

  test "completed command output-fetch failure preserves provider exit status" do
    sandbox = %FakeRemoteSandbox{
      provider_id: "remote",
      sandbox_id: "sbx-2",
      mode: :output_fetch_failure
    }

    assert %Sandbox.ExecuteResult{exit_code: 42, error: "output_unavailable", metadata: metadata} =
             Sandbox.execute(sandbox, "run-job", command_id: "cmd-output")

    assert metadata.command_id == "cmd-output"
    assert metadata.exit_code == 42
    assert metadata.output_unavailable == true
    assert metadata.raw_status == "finished"
  end

  test "remote sandbox metadata is redacted at the execution boundary" do
    sandbox = %FakeRemoteSandbox{provider_id: "remote", sandbox_id: "sbx-3"}

    assert %Sandbox.ExecuteResult{metadata: metadata} =
             Sandbox.execute(sandbox, "echo ok", command_id: "cmd-ok")

    assert metadata.api_key == "**REDACTED**"
    assert metadata.provider_id == "remote"
    assert metadata.sandbox_id == "sbx-3"
  end

  def handle_telemetry(event, measurements, metadata, {pid, ref}) do
    send(pid, {ref, event, measurements, metadata})
  end
end
