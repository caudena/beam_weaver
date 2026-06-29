defmodule BeamWeaver.Anthropic.MiddlewareTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.Middleware.AnthropicTools
  alias BeamWeaver.Anthropic.Middleware.Bash
  alias BeamWeaver.Anthropic.Middleware.FileSearch
  alias BeamWeaver.Anthropic.Middleware.PromptCaching

  test "prompt caching middleware exposes Anthropic cache_control call opts" do
    assert PromptCaching.new().cache_control == %{type: :ephemeral}

    assert PromptCaching.new() |> PromptCaching.call_opts() == [
             cache_control: %{type: :ephemeral}
           ]
  end

  test "tool middleware exposes bound Anthropic tool declarations" do
    middleware =
      AnthropicTools.new([
        %{"name" => "lookup", "description" => "Lookup", "input_schema" => %{}}
      ])

    assert AnthropicTools.call_opts(middleware)[:tools] == [
             %{"name" => "lookup", "description" => "Lookup", "input_schema" => %{}}
           ]
  end

  test "server tool helpers expose expected tool declarations" do
    assert Bash.new() |> Bash.call_opts() == [tools: [%{"type" => "bash_20250124"}]]

    assert FileSearch.new() |> FileSearch.call_opts() == [
             tools: [%{"type" => "tool_search_tool_bm25_20251119"}]
           ]
  end
end
