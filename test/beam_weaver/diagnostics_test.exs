defmodule BeamWeaver.DiagnosticsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BeamWeaver.Diagnostics

  setup do
    previous = System.get_env("BEAM_WEAVER_DIAGNOSTICS_TEST")

    on_exit(fn ->
      if previous,
        do: System.put_env("BEAM_WEAVER_DIAGNOSTICS_TEST", previous),
        else: System.delete_env("BEAM_WEAVER_DIAGNOSTICS_TEST")
    end)

    System.delete_env("BEAM_WEAVER_DIAGNOSTICS_TEST")
    :ok
  end

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

  test "environment helpers avoid implicit globals and atom creation" do
    refute Diagnostics.env_var_set?("BEAM_WEAVER_DIAGNOSTICS_TEST")

    assert {:ok, "fallback"} =
             Diagnostics.get_from_env("BEAM_WEAVER_DIAGNOSTICS_TEST", default: "fallback")

    assert {:error, %{type: :missing_environment_variable}} =
             Diagnostics.get_from_env("BEAM_WEAVER_DIAGNOSTICS_TEST")

    System.put_env("BEAM_WEAVER_DIAGNOSTICS_TEST", "from-env")
    assert Diagnostics.env_var_set?("BEAM_WEAVER_DIAGNOSTICS_TEST")

    assert {:ok, "from-map"} =
             Diagnostics.get_from_map_or_env(
               %{"api_key" => "from-map"},
               :api_key,
               "BEAM_WEAVER_DIAGNOSTICS_TEST"
             )

    unknown_key = "beam_weaver_unknown_key_#{System.unique_integer([:positive])}"

    assert {:ok, "from-env"} =
             Diagnostics.get_from_map_or_env(%{}, unknown_key, "BEAM_WEAVER_DIAGNOSTICS_TEST")

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end
  end
end
