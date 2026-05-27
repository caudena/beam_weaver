defmodule BeamWeaver.ExamplesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @examples Path.wildcard(Path.expand("../../../examples/*.exs", __DIR__))
            |> Enum.reject(&String.ends_with?(&1, "supervised_openai_agent.exs"))
            |> Enum.sort()

  @deepagents_examples Path.wildcard(Path.expand("../../../examples/deepagents/*.exs", __DIR__))
                       |> Enum.sort()

  test "non-live examples run without network credentials" do
    for path <- @examples do
      output =
        capture_io(fn ->
          Code.eval_file(path)
        end)

      assert output != "", "#{Path.basename(path)} should print a visible result"
    end
  end

  test "DeepAgents examples run without network credentials" do
    assert length(@deepagents_examples) == 15

    for path <- @deepagents_examples do
      output =
        capture_io(fn ->
          Code.eval_file(path)
        end)

      assert output != "", "#{Path.basename(path)} should print a visible result"
    end
  end
end
