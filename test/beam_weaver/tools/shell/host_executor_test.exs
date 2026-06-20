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
end
