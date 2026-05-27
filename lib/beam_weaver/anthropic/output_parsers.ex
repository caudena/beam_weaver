defmodule BeamWeaver.Anthropic.OutputParsers do
  @moduledoc """
  Anthropic output parsing helpers.
  """

  @doc """
  Extracts tool calls from Anthropic `tool_use` content blocks.
  """
  @spec extract_tool_calls([map()] | term()) :: [map()]
  def extract_tool_calls(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "tool_use"))
    |> Enum.map(fn block ->
      BeamWeaver.Core.Messages.tool_call(
        id: block["id"],
        provider_id: block["id"],
        call_id: block["id"],
        name: block["name"],
        args: block["input"] || %{}
      )
    end)
  end

  def extract_tool_calls(_content), do: []
end
