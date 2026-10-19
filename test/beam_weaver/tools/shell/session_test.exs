defmodule BeamWeaver.Tools.Shell.SessionTest.TrustingExecutor do
  @moduledoc false
  @behaviour BeamWeaver.Tools.Shell.Executor

  @impl true
  def run(_command, _policy, _opts), do: {:ok, %{status: 0, output: ""}}
end

defmodule BeamWeaver.Tools.Shell.SessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BeamWeaver.Tools.Shell.Session

  test "a session refuses to start with a custom executor" do
    assert {:error, %{type: :shell_session_executor_unsupported, details: %{executor: executor}}} =
             GenServer.start(Session, policy: [allow: ["ls"], executor: __MODULE__.TrustingExecutor])

    assert executor =~ "TrustingExecutor"
  end

  test "a session keeps its environment out of inspected and reported state" do
    secret = "hunter2-#{System.unique_integer([:positive])}"
    {:ok, session} = GenServer.start(Session, policy: [allow: ["true"], env: %{"DB_PASSWORD" => secret}])

    refute inspect(:sys.get_state(session)) =~ secret
    refute inspect(:sys.get_status(session)) =~ secret

    Session.shutdown(session)
  end

  test "a session stops itself after its idle timeout so an abandoned run doesn't leak it" do
    {:ok, session} = GenServer.start(Session, policy: [allow: ["true"]], idle_timeout: 50)
    ref = Process.monitor(session)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 1_000
  end

  @tag :tmp_dir
  test "zero-timeout commands leak no scratch dirs, shell errors, or port messages",
       %{tmp_dir: tmp_dir} do
    isolate_tmp_dir(tmp_dir)

    {:ok, pid} =
      GenServer.start(Session, policy: [allow: [~r/.*/], stderr: :separate, timeout: 0])

    before = scratch_dirs()

    captured =
      capture_io(:stderr, fn ->
        assert {:error, %{type: :shell_timeout, details: %{metadata: metadata}}} =
                 Session.execute(pid, "sleep 5", timeout: 0, command_id: "cmd-timeout")

        assert metadata.command_id == "cmd-timeout"
        assert metadata.kill_attempted == true
        assert metadata.error == "timeout"
      end)

    assert captured == ""
    assert scratch_dirs() == before
    assert port_messages(pid) == []

    Session.shutdown(pid)
  end

  test "session command results include native metadata" do
    {:ok, pid} =
      GenServer.start(Session, policy: [allow: ["printf"], timeout: 5_000])

    assert {:ok, %{status: 0, output: "ok", metadata: metadata}} =
             Session.execute(pid, "printf ok", command_id: "cmd-ok")

    assert metadata.backend == :session
    assert metadata.command_id == "cmd-ok"
    assert metadata.exit_code == 0

    Session.shutdown(pid)
  end

  # Session and executor scratch dirs live under `System.tmp_dir!/0`. Pointing
  # TMPDIR at this test's own directory keeps scratch dirs from other suites that
  # share the system temp dir out of the before/after comparison.
  defp isolate_tmp_dir(tmp_dir) do
    previous = System.get_env("TMPDIR")
    System.put_env("TMPDIR", tmp_dir)

    on_exit(fn ->
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
    end)
  end

  defp scratch_dirs do
    System.tmp_dir!()
    |> Path.join("beam_weaver_shell_scratch_*")
    |> Path.wildcard()
    |> MapSet.new()
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
end
