defmodule BeamWeaver.Tools.Shell.SessionTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Tools.Shell.Session

  test "does not leak metadata, env, or stderr temp files when a command times out" do
    {:ok, pid} =
      Session.start(policy: [allow: ["sleep"], stderr: :separate, timeout: 50])

    before = session_temp_files()

    assert {:error, %{type: :shell_timeout}} = Session.execute(pid, "sleep 5", timeout: 50)

    Process.sleep(100)

    assert session_temp_files() == before

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
