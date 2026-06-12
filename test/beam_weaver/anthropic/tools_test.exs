defmodule BeamWeaver.Anthropic.ToolsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.Tools
  alias BeamWeaver.Core.Tool

  test "renders BeamWeaver tools as Anthropic custom tools" do
    tool =
      Tool.from_function!(
        name: "get_weather",
        description: "Get weather for a city",
        input_schema: %{
          type: "object",
          properties: %{city: %{type: "string"}},
          required: [:city]
        },
        handler: fn _args, _opts -> {:ok, "sunny"} end
      )

    assert Tools.function(tool, strict: true, cache_control: %{type: :ephemeral}) == %{
             "name" => "get_weather",
             "description" => "Get weather for a city",
             "input_schema" => %{
               "type" => "object",
               "properties" => %{"city" => %{"type" => "string"}},
               "required" => ["city"],
               "additionalProperties" => false
             },
             "strict" => true,
             "cache_control" => %{type: :ephemeral}
           }
  end

  test "passes through built-in tools and infers beta headers" do
    tools = [
      Tools.web_fetch(),
      Tools.code_execution(),
      Tools.advisor(),
      %{
        "name" => "search",
        "description" => "Search",
        "input_schema" => %{"type" => "object"},
        "input_examples" => [%{"query" => "beam"}]
      }
    ]

    assert Enum.at(tools, 0)["type"] == "web_fetch_20260309"
    assert Enum.at(tools, 1)["type"] == "code_execution_20260120"
    assert Enum.at(tools, 2)["type"] == "advisor_20260301"

    assert Tools.required_betas(tools, ["existing-beta"]) == [
             "existing-beta",
             "web-fetch-2026-03-09",
             "code-execution-2026-01-20",
             "advisor-2026-03-01",
             "advanced-tool-use-2025-11-20"
           ]
  end

  test "normalizes tool choice and parallel-tool controls" do
    assert Tools.tool_choice("get_weather") == %{"type" => "tool", "name" => "get_weather"}
    assert Tools.tool_choice(:any) == %{"type" => "any"}

    assert Tools.tool_choice(:auto, parallel_tool_calls: false) == %{
             "type" => "auto",
             "disable_parallel_tool_use" => true
           }
  end
end
