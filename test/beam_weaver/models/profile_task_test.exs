defmodule BeamWeaver.Models.ProfileTaskTest do
  use ExUnit.Case, async: false

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "profiles Mix task prints deterministic provider-scoped text output" do
    Mix.Task.rerun("beam_weaver.models.profiles", ["--provider", "openai"])

    assert_receive {:mix_shell, :info, [output]}
    assert output =~ "openai:gpt-5.5"
    refute output =~ "fake:chat"
  end

  test "profiles Mix task can emit JSON-compatible profile data" do
    Mix.Task.rerun("beam_weaver.models.profiles", ["--provider", "fake", "--json"])

    assert_receive {:mix_shell, :info, [output]}
    assert {:ok, profiles} = BeamWeaver.JSON.decode(output)
    assert Enum.map(profiles, & &1["provider"]) == ["fake", "fake"]
    assert Enum.any?(profiles, &(&1["id"] == "chat" and &1["tool_calling"] == true))
  end

  test "profiles Mix task refreshes provider data from explicit source JSON" do
    root = tmp_dir("profile-task")
    data_dir = Path.join(root, "data")
    source_path = Path.join(root, "models.json")

    File.write!(source_path, BeamWeaver.JSON.encode!(source_data()))

    Mix.Task.rerun("beam_weaver.models.profiles", [
      "--refresh",
      "--provider",
      "anthropic",
      "--data-dir",
      data_dir,
      "--source-json",
      source_path,
      "--yes"
    ])

    assert_receive {:mix_shell, :info, [output]}
    assert output =~ "Refreshed 1 profiles"

    artifact = Path.join(data_dir, "profiles.json")
    assert File.exists?(artifact)

    assert {:ok, %{"provider" => "anthropic", "profiles" => [%{"id" => "claude-3-opus"}]}} =
             artifact |> File.read!() |> BeamWeaver.JSON.decode()
  end

  defp source_data do
    %{
      "anthropic" => %{
        "id" => "anthropic",
        "models" => %{
          "claude-3-opus" => %{
            "id" => "claude-3-opus",
            "name" => "Claude 3 Opus",
            "tool_call" => true,
            "limit" => %{"context" => 200_000, "output" => 4_096},
            "modalities" => %{"input" => ["text", "image"], "output" => ["text"]}
          }
        }
      }
    }
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
