defmodule BeamWeaver.OpenAI.MessageParts do
  @moduledoc false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.MapShape

  @output_block_types MapSet.new([
                        "additional_tools",
                        "reasoning",
                        "computer_call",
                        "computer_call_output",
                        "web_search_call",
                        "file_search_call",
                        "code_interpreter_call",
                        "local_shell_call",
                        "local_shell_call_output",
                        "shell_call",
                        "shell_call_output",
                        "program",
                        "program_output",
                        "mcp_call",
                        "mcp_list_tools",
                        "mcp_approval_request",
                        "mcp_approval_response",
                        "image_generation_call",
                        "tool_search_call",
                        "tool_search_output",
                        "custom_tool_call",
                        "custom_tool_call_output",
                        "apply_patch_call",
                        "apply_patch_call_output",
                        "compaction",
                        "function_call",
                        "function_call_output"
                      ])

  @input_token_details [
    cache_read: "cached_tokens",
    cache_write: "cache_write_tokens",
    audio: "audio_tokens",
    image: "image_tokens",
    text: "text_tokens",
    flex: "flex"
  ]

  @output_token_details [
    reasoning: "reasoning_tokens",
    accepted_prediction: "accepted_prediction_tokens",
    rejected_prediction: "rejected_prediction_tokens",
    audio: "audio_tokens",
    image: "image_tokens",
    text: "text_tokens",
    flex: "flex",
    flex_reasoning: "flex_reasoning"
  ]

  def output_block_type?(type), do: MapSet.member?(@output_block_types, type)

  def stringify_keys(map) when is_map(map), do: MapShape.stringify_keys(map)

  def stringify_value(value), do: MapShape.normalize_value(value)

  def reject_nil_values(map) when is_map(map), do: MapShape.reject_nil_values(map)

  def put_optional(body, _key, nil), do: body
  def put_optional(body, key, value), do: Map.put(body, key, value)

  def data_url(mime_type, data), do: "data:#{mime_type};base64,#{data}"

  def audio_format("audio/" <> format), do: format
  def audio_format(format) when is_binary(format), do: format
  def audio_format(_format), do: "wav"

  def block_option(block, key) do
    metadata = Map.get(block, :metadata, %{}) || %{}

    Map.get(block, key) || Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  def put_prompt_cache_breakpoint(part, block) do
    case block_option(block, :prompt_cache_breakpoint) do
      breakpoint when is_map(breakpoint) -> Map.put(part, "prompt_cache_breakpoint", stringify_keys(breakpoint))
      _missing -> part
    end
  end

  def provider_role(%Message{} = message), do: to_string(Map.get(message.metadata, :openai_role) || message.role)

  def usage_metadata(usage, :chat_completions), do: usage_metadata(usage, "prompt", "completion", "input", "output")
  def usage_metadata(usage, :responses), do: usage_metadata(usage, "input", "output", "prompt", "completion")

  defp usage_metadata(usage, input, output, other_input, other_output) do
    input_tokens = usage[input <> "_tokens"] || usage[other_input <> "_tokens"]
    output_tokens = usage[output <> "_tokens"] || usage[other_output <> "_tokens"]
    input_details = usage[input <> "_tokens_details"] || usage[other_input <> "_tokens_details"]
    output_details = usage[output <> "_tokens_details"] || usage[other_output <> "_tokens_details"]

    MapShape.reject_nil_or_empty(%{
      input_tokens: input_tokens || 0,
      output_tokens: output_tokens || 0,
      total_tokens: total_tokens(usage["total_tokens"], input_tokens, output_tokens),
      input_token_details: token_details(input_details, @input_token_details),
      output_token_details: token_details(output_details, @output_token_details)
    })
  end

  defp total_tokens(total, _input, _output) when is_integer(total), do: total
  defp total_tokens(_total, input, output) when is_integer(input) and is_integer(output), do: input + output
  defp total_tokens(_total, _input, _output), do: nil

  defp token_details(details, fields) when is_map(details),
    do: fields |> Map.new(fn {key, field} -> {key, details[field]} end) |> MapShape.reject_nil_or_empty()

  defp token_details(_details, _fields), do: %{}
end
