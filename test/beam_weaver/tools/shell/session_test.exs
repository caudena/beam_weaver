defmodule BeamWeaver.Tools.Shell.SessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BeamWeaver.Tools.Shell.Session

  test "zero-timeout commands do not leak scratch or emit shell errors before delayed trailers" do
    probe_root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_shell_timeout_probe_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(probe_root)
    on_exit(fn -> File.rm_rf(probe_root) end)

    completed_path = Path.join(probe_root, "completed")

    delayed_write =
      "sleep 0.05; printf late > \"$1/metadata\"; " <>
        "printf done > #{shell_quote(completed_path)}"

    scratch_glob = shell_quote(System.tmp_dir!()) <> "/beam_weaver_shell_scratch_*"

    command =
      "set -- #{scratch_glob}; scratch_dir=$1; " <>
        "nohup sh -c #{shell_quote(delayed_write)} sh \"$scratch_dir\" >/dev/null 2>&1 & " <>
        "sleep 0.2"

    {:ok, pid} =
      Session.start(policy: [allow: [~r/.*/], stderr: :separate, timeout: 0])

    before = scratch_dirs()

    captured =
      capture_io(:stderr, fn ->
        assert {:error, %{type: :shell_timeout, details: %{metadata: metadata}}} =
                 Session.execute(
                   pid,
                   command,
                   timeout: 0,
                   command_id: "cmd-timeout"
                 )

        assert metadata.command_id == "cmd-timeout"
        assert metadata.kill_attempted == true
        assert metadata.error == "timeout"
      end)

    assert captured == ""
    assert scratch_dirs() == before
    assert port_messages(pid) == []

    assert eventually(fn -> File.read(completed_path) == {:ok, "done"} end)
    assert scratch_dirs() == before
    assert port_messages(pid) == []

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

  defp eventually(predicate, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(predicate, deadline)
  end

  defp do_eventually(predicate, deadline) do
    if predicate.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        receive do
        after
          5 -> do_eventually(predicate, deadline)
        end
      end
    end
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
