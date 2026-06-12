defmodule BeamWeaver.ConfigTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Config

  test "reads grouped application config and treats blank values as missing" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:openai,
      api_key: "sk-config",
      organization: "",
      project: "   "
    )

    assert Config.get([:openai, :api_key]) == "sk-config"
    assert Config.get([:openai, :organization], "default-org") == "default-org"
    assert Config.get([:openai, :project], "default-project") == "default-project"
    assert Config.get([:openai, :missing], "default") == "default"
  end

  test "explicit keyword options including nil win over config defaults" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:openai, api_key: "sk-config")

    assert Config.option([], :api_key, [:openai, :api_key]) == "sk-config"
    assert Config.option([api_key: "sk-explicit"], :api_key, [:openai, :api_key]) == "sk-explicit"
    assert Config.option([api_key: nil], :api_key, [:openai, :api_key]) == nil
  end

  test "group returns configured groups with fallback" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:weave_scope, endpoint: "https://app.weavescope.com")

    assert Config.group(:weave_scope) == [endpoint: "https://app.weavescope.com"]
    assert Config.group(:missing_group, retries: 1) == [retries: 1]
  end

  test "runtime config reads stay centralized" do
    root = Path.expand("../..", __DIR__)

    assert_no_forbidden_refs(root, ~r/System\.(get_env|put_env|delete_env)/, [
      "lib/beam_weaver/diagnostics.ex",
      "lib/beam_weaver/filesystem/local_shell.ex"
    ])

    assert_no_forbidden_refs(root, ~r/Application\.get_env/, [
      "lib/beam_weaver/config.ex",
      "support/config_helper.exs"
    ])
  end

  defp assert_no_forbidden_refs(root, regex, allowed) do
    offenders =
      root
      |> runtime_files()
      |> Enum.reject(&(&1 in allowed))
      |> Enum.flat_map(fn relative_path ->
        full_path = Path.join(root, relative_path)

        full_path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_number} ->
          if Regex.match?(regex, line), do: ["#{relative_path}:#{line_number}: #{line}"], else: []
        end)
      end)

    assert offenders == []
  end

  defp runtime_files(root) do
    ["examples", "lib", "support"]
    |> Enum.flat_map(fn dir ->
      root
      |> Path.join(dir)
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
    end)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(&String.contains?(&1, "/deps/"))
    |> Enum.sort()
  end
end
