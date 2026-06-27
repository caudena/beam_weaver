defmodule BeamWeaver.Tools.Shell.SessionTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Tools.Shell.Session

  test "does not leak metadata, env, or stderr temp files when a command times out" do
    {:ok, pid} =
      Session.start(policy: [allow: ["sleep"], stderr: :separate, timeout: 50])

    before = session_temp_files()

    assert {:error, %{type: :shell_timeout, details: %{metadata: metadata}}} =
             Session.execute(pid, "sleep 5", timeout: 50, command_id: "cmd-timeout")

    assert metadata.command_id == "cmd-timeout"
    assert metadata.kill_attempted == true
    assert metadata.error == "timeout"

    Process.sleep(100)

    assert session_temp_files() == before

    Session.shutdown(pid)
  end

  test "session command results include native metadata" do
    {:ok, pid} =
      Session.start(policy: [allow: ["printf"], timeout: 500])

    assert {:ok, %{status: 0, output: "ok", metadata: metadata}} =
             Session.execute(pid, "printf ok", command_id: "cmd-ok")

    assert metadata.backend == :session
    assert metadata.command_id == "cmd-ok"
    assert metadata.exit_code == 0

    Session.shutdown(pid)
  end

  defp session_temp_files do
    ["metadata", "env", "stderr"]
    |> Enum.flat_map(fn label ->
      System.tmp_dir!()
      |> Path.join("beam_weaver_shell_#{label}_*")
      |> Path.wildcard()
    end)
    |> MapSet.new()
  end
end
