defmodule BeamWeaver.Tools.Shell.HostExecutorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

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

  test "closes command stdin like System.cmd" do
    policy = ShellPolicy.new!(allow: ["cat"], timeout: 1_000)

    assert {:ok, %{status: 0, output: ""}} = HostExecutor.run("cat", policy)
  end

  test "separate stderr preserves shell syntax failures and nonzero status" do
    policy = ShellPolicy.new!(allow: [~r/.*/], stderr: :separate, timeout: 1_000)

    assert {:ok, %{status: status, output: "", stderr: stderr}} =
             HostExecutor.run("(", policy)

    assert status > 0
    assert stderr != ""
  end

  test "zero-timeout separate-stderr commands emit no shell errors or scratch leaks" do
    policy = ShellPolicy.new!(allow: ["sleep"], stderr: :separate, timeout: 0)

    before = scratch_dirs()

    captured =
      capture_io(:stderr, fn ->
        for iteration <- 1..25 do
          assert {:error, %{type: :shell_timeout}} =
                   HostExecutor.run("sleep 0.01", policy, command_id: "host-timeout-#{iteration}")
        end
      end)

    assert captured == ""
    assert scratch_dirs() == before
    assert port_messages(self()) == []
  end

  defp port_messages(pid) do
    pid
    |> Process.info(:messages)
    |> elem(1)
    |> Enum.filter(fn
      {port, _message} when is_port(port) -> true
      {:EXIT, port, _reason} when is_port(port) -> true
      _message -> false
    end)
  end

  defp scratch_dirs do
    System.tmp_dir!()
    |> Path.join("beam_weaver_shell_scratch_*")
    |> Path.wildcard()
    |> MapSet.new()
  end
end
