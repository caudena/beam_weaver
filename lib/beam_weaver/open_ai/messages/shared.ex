defmodule BeamWeaver.OpenAI.Messages.Shared do
  @moduledoc false

  @output_block_types MapSet.new([
                        "reasoning",
                        "web_search_call",
                        "file_search_call",
                        "code_interpreter_call",
                        "mcp_call",
                        "mcp_list_tools",
                        "mcp_approval_request",
                        "image_generation_call",
                        "tool_search_call",
                        "tool_search_output",
                        "custom_tool_call",
                        "custom_tool_call_output",
                        "apply_patch_call",
                        "apply_patch_call_output",
                        "compaction",
                        "function_call"
                      ])

  def output_block_type?(type), do: MapSet.member?(@output_block_types, type)

  def stringify_keys(map) when is_map(map), do: BeamWeaver.MapShape.stringify_keys(map)

  def stringify_value(value), do: BeamWeaver.MapShape.normalize_value(value)

  def reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  def put_optional(body, _key, nil), do: body
  def put_optional(body, key, value), do: Map.put(body, key, value)

  def audio_format("audio/" <> format), do: format
  def audio_format(format) when is_binary(format), do: format
  def audio_format(_format), do: "wav"

  def data_url(mime_type, data), do: "data:#{mime_type};base64,#{data}"
end
