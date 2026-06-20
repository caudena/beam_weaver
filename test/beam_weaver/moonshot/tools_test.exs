defmodule BeamWeaver.Moonshot.ToolsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Moonshot.Tools

  defp function_tool(name) do
    %{"type" => "function", "function" => %{"name" => name, "parameters" => %{"type" => "object"}}}
  end

  test "accepts short, digit-leading, and hyphen-leading function names" do
    for name <- ["a", "7tool", "-x", "get_weather", String.duplicate("a", 64)] do
      assert :ok = Tools.validate_chat_tools([function_tool(name)]),
             "expected #{inspect(name)} to be a valid Moonshot function tool name"
    end
  end

  test "rejects empty, over-long, and invalid-character names" do
    for name <- ["", String.duplicate("a", 65), "has space", "bad/name"] do
      assert {:error, _} = Tools.validate_chat_tools([function_tool(name)]),
             "expected #{inspect(name)} to be rejected"
    end
  end
end
