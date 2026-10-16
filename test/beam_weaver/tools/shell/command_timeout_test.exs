defmodule BeamWeaver.Tools.Shell.CommandTimeoutTest.Helpers do
  @moduledoc false

  import BeamWeaver.TestSupport.Eventually
  import ExUnit.Assertions

  # A command that starts a background job, records both pids and then waits
  # for the job, so only a timeout can end it.
  def process_tree(dir) do
    "sleep 60 & echo $! > #{shell_quote(Path.join(dir, "job.pid"))}; " <>
      "echo $$ > #{shell_quote(Path.join(dir, "shell.pid"))}; wait"
  end

  # Every process the command got to record is gone. On a loaded machine the
  # timeout can fire before the shell records anything; then there is nothing
  # to check. A killed process may take a moment to be reaped on a busy
  # machine, so the check waits up to 15 seconds.
  def assert_killed(dir) do
    for name <- ["shell.pid", "job.pid"], {:ok, pid} <- [File.read(Path.join(dir, name))] do
      pid = String.trim(pid)
      assert eventually(fn -> not os_process_alive?(pid) end, 15_000), "#{name} (#{pid}) is still running"
    end
  end

  def shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp os_process_alive?(pid) do
    {_output, status} = System.cmd("sh", ["-c", "kill -0 #{pid} 2>/dev/null"])
    status == 0
  end
end

defmodule BeamWeaver.Tools.Shell.CommandTimeoutTest do
  use ExUnit.Case, async: true

  import BeamWeaver.Tools.Shell.CommandTimeoutTest.Helpers

  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tools.Shell.CommandRunner
  alias BeamWeaver.Tools.Shell.HostExecutor
  alias BeamWeaver.Tools.Shell.Session

  @moduletag :tmp_dir

  test "host executor timeouts kill the command and its background jobs", %{tmp_dir: dir} do
    policy = ShellPolicy.new!(allow: [~r/.*/], allow_compound: true, timeout: 500)

    assert {:error, %{type: :shell_timeout, details: %{metadata: %{kill_attempted: true}}}} =
             HostExecutor.run(process_tree(dir), policy)

    assert_killed(dir)
  end

  test "timed-out commands get SIGTERM first so they can clean up", %{tmp_dir: dir} do
    trap_set = Path.join(dir, "trap_set")
    cleaned_up = Path.join(dir, "cleaned_up")

    # The shell spins on builtins instead of waiting on a child: when the same
    # group SIGTERM also kills the child it waits on, the shell can drop its
    # TERM trap and simply carry on (seen with macOS `/bin/sh`).
    command =
      "trap 'echo done > #{shell_quote(cleaned_up)}; exit 0' TERM; " <>
        ": > #{shell_quote(trap_set)}; while :; do :; done"

    # The long grace period only matters on a starved machine: the runner moves
    # on as soon as the shell exits.
    assert {:timeout, true} =
             CommandRunner.run(command, shell: CommandRunner.shell(), timeout: 500, term_grace: 30_000)

    # A starved shell may not reach its `trap` before the timeout; once it has,
    # the handler must have run before the call returned.
    if File.exists?(trap_set), do: assert(File.read!(cleaned_up) == "done\n")
  end

  test "processes that ignore SIGTERM are killed after the grace period", %{tmp_dir: dir} do
    policy = ShellPolicy.new!(allow: [~r/.*/], allow_compound: true, timeout: 500)

    assert {:error, %{type: :shell_timeout}} =
             HostExecutor.run("trap '' TERM; " <> process_tree(dir), policy)

    assert_killed(dir)
  end

  test "session timeouts kill the command and its background jobs, even past SIGTERM",
       %{tmp_dir: dir} do
    {:ok, session} = Session.start(policy: [allow: [~r/.*/], allow_compound: true, timeout: 500])

    assert {:error, %{type: :shell_timeout, details: %{metadata: %{kill_attempted: true}}}} =
             Session.execute(session, "trap '' TERM; " <> process_tree(dir))

    assert_killed(dir)
    Session.shutdown(session)
  end

  test "a command is stopped when its caller dies before the runner returns", %{tmp_dir: dir} do
    # No timeout: only the caller's death can end the command, so the guardian
    # (not the runner's own receive loop) must stop the process group.
    caller =
      spawn(fn ->
        CommandRunner.run(process_tree(dir), shell: CommandRunner.shell(), timeout: :infinity)
      end)

    # Let the shell record its pids, then kill the caller with an untrappable
    # exit, as `Task.shutdown(task, :brutal_kill)` would.
    wait_for_pids(dir)
    Process.exit(caller, :kill)

    assert_killed(dir)
  end

  defp wait_for_pids(dir) do
    import BeamWeaver.TestSupport.Eventually

    assert eventually(fn ->
             Enum.all?(["shell.pid", "job.pid"], &File.exists?(Path.join(dir, &1)))
           end)
  end
end

defmodule BeamWeaver.Tools.Shell.LocalBackendTimeoutTest do
  use ExUnit.Case, async: true

  import BeamWeaver.Tools.Shell.CommandTimeoutTest.Helpers

  alias BeamWeaver.Filesystem.Executable.ExecuteResult
  alias BeamWeaver.Filesystem.LocalShell
  alias BeamWeaver.Sandbox

  @moduletag :tmp_dir

  test "local shell backend timeouts kill the command and its background jobs", %{tmp_dir: dir} do
    assert %ExecuteResult{exit_code: 124, error: "timeout"} =
             LocalShell.execute(LocalShell.new(root: dir), process_tree(dir), timeout: 1)

    assert_killed(dir)
  end

  test "local sandbox timeouts kill the command and its background jobs", %{tmp_dir: dir} do
    assert %Sandbox.ExecuteResult{exit_code: 124, error: "timeout"} =
             Sandbox.execute(Sandbox.local(root: dir), process_tree(dir), timeout: 1)

    assert_killed(dir)
  end

  test "local backends give commands EOF on stdin instead of waiting for input", %{tmp_dir: dir} do
    assert %ExecuteResult{exit_code: 0, output: ""} =
             LocalShell.execute(LocalShell.new(root: dir), "cat", timeout: 30)

    assert %Sandbox.ExecuteResult{exit_code: 0, output: ""} =
             Sandbox.execute(Sandbox.local(root: dir), "cat", timeout: 30)
  end
end
