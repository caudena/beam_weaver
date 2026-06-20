defmodule BeamWeaver.Tools.Shell.HostExecutorTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tools.Shell.HostExecutor

  test "runs a command under a policy with timeout: nil without crashing" do
    policy = ShellPolicy.new!(allow: ["echo"], timeout: nil)

    assert {:ok, result} = HostExecutor.run("echo beam_weaver", policy)
    assert result.output =~ "beam_weaver"
  end

  test "honors an explicit integer timeout" do
    policy = ShellPolicy.new!(allow: ["echo"], timeout: 5_000)

    assert {:ok, result} = HostExecutor.run("echo ok", policy)
    assert result.output =~ "ok"
  end

  test "does not leak stderr temp files when a separate-stderr command times out" do
    policy = ShellPolicy.new!(allow: ["sleep"], stderr: :separate, timeout: 50)

    before = stderr_temp_files()

    assert {:error, %{type: :shell_timeout}} = HostExecutor.run("sleep 5", policy)

    Process.sleep(100)

    assert stderr_temp_files() == before
  end

  defp stderr_temp_files do
    System.tmp_dir!()
    |> Path.join("beam_weaver_shell_stderr_*")
    |> Path.wildcard()
    |> MapSet.new()
  end
end
