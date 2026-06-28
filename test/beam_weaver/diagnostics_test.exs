defmodule BeamWeaver.DiagnosticsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BeamWeaver.Diagnostics

  test "runtime environment returns deterministic public diagnostics" do
    env = Diagnostics.runtime_environment()

    assert env["beam_weaver_version"] != ""
    assert env["elixir_version"] == System.version()
    assert env["otp_release"] == System.otp_release()
    assert is_integer(env["schedulers"])
  end

  test "print_sys_info writes sorted key value diagnostics" do
    output = capture_io(fn -> Diagnostics.print_sys_info() end)

    assert output =~ "beam_weaver_version:"
    assert output =~ "elixir_version:"
    assert output =~ "otp_release:"
  end
end
