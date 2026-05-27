defmodule BeamWeaver.InternalShapeTest do
  use ExUnit.Case, async: true

  @atom_only_internal_files [
    "lib/beam_weaver/agent/compiler/routing.ex",
    "lib/beam_weaver/agent/final_response_policy.ex",
    "lib/beam_weaver/agent/middleware/context_editing.ex",
    "lib/beam_weaver/agent/middleware/filesystem.ex",
    "lib/beam_weaver/agent/middleware/human_in_the_loop.ex",
    "lib/beam_weaver/agent/middleware/offload.ex",
    "lib/beam_weaver/agent/middleware/overflow_recovery.ex",
    "lib/beam_weaver/agent/middleware/pii.ex",
    "lib/beam_weaver/agent/middleware/prompt_caching.ex",
    "lib/beam_weaver/agent/middleware/subagents.ex",
    "lib/beam_weaver/agent/middleware/summarization.ex",
    "lib/beam_weaver/agent/middleware/todo_list.ex",
    "lib/beam_weaver/agent/middleware/tool_call_limit.ex",
    "lib/beam_weaver/agent/middleware/tool_call_normalization.ex",
    "lib/beam_weaver/agent/middleware/tool_retry.ex",
    "lib/beam_weaver/agent/middleware/tool_selection.ex",
    "lib/beam_weaver/agent/nodes/model/prompt.ex",
    "lib/beam_weaver/agent/nodes/model/response.ex",
    "lib/beam_weaver/agent/structured_output/result_handler.ex",
    "lib/beam_weaver/agent/usage.ex",
    "lib/beam_weaver/anthropic/chat_model/request_builder.ex",
    "lib/beam_weaver/core/chat_model.ex",
    "lib/beam_weaver/core/message.ex",
    "lib/beam_weaver/core/message_like.ex",
    "lib/beam_weaver/core/messages/buffer.ex",
    "lib/beam_weaver/core/messages/message_chunk.ex",
    "lib/beam_weaver/core/messages/open_ai.ex",
    "lib/beam_weaver/core/messages/trim.ex",
    "lib/beam_weaver/core/messages/utils.ex",
    "lib/beam_weaver/google/messages.ex",
    "lib/beam_weaver/open_ai/chat_completions/messages/request.ex",
    "lib/beam_weaver/open_ai/client/response_decoder.ex",
    "lib/beam_weaver/open_ai/messages/request.ex",
    "lib/beam_weaver/open_ai/responses.ex",
    "lib/beam_weaver/provider/response.ex",
    "lib/beam_weaver/provider/structured_output.ex",
    "lib/beam_weaver/xai/client/response_decoder.ex"
  ]

  @string_internal_lookup ~r/\b(metadata|response_metadata|call|tool_call|chunk)\s*\[\s*"[^"]+"\s*\]|Map\.get\(\b(metadata|response_metadata|call|tool_call|chunk),\s*"[^"]+"/
  @usage_internal_lookup ~r/\busage\s*\[\s*"[^"]+"\s*\]|Map\.get\(usage,\s*"[^"]+"|Map\.get\(input_details,\s*"[^"]+"|Map\.get\(output_details,\s*"[^"]+"/
  @map_access_internal_lookup ~r/(BeamWeaver\.)?MapAccess\.get\(\b(metadata|response_metadata|call|tool_call|chunk)/
  @state_messages_lookup ~r/state\[\s*"messages"\s*\]|Map\.get\(state,\s*"messages"|Map\.get\(state,\s*:messages,\s*Map\.get\(state,\s*"messages"/
  @message_chunk_string_shape ~r/Map\.(has_key\?|put)\(map,\s*"[^"]+"/
  @string_content_block_input ~r/defp\s+(content_block_to_openai|content_part|assistant_content_event|content_block_to_chat_completion)\(%\{"type"/
  @middleware_string_content ~r/%\{"type" => "(text|plain_text)"|%\{"text" =>|Map\.put\(block,\s*"cache_control"|Map\.get\([^,\n]+,\s*"type"/

  test "selected internal paths do not reintroduce string-key metadata or tool-call lookups" do
    root = Path.expand("../..", __DIR__)

    offenders =
      @atom_only_internal_files
      |> Enum.flat_map(fn path ->
        root
        |> Path.join(path)
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_number} ->
          if Regex.match?(@string_internal_lookup, line) or
               Regex.match?(@map_access_internal_lookup, line) or
               Regex.match?(@state_messages_lookup, line) or
               (path == "lib/beam_weaver/provider/response.ex" and
                  Regex.match?(@usage_internal_lookup, line)) or
               (path == "lib/beam_weaver/core/messages/message_chunk.ex" and
                  Regex.match?(@message_chunk_string_shape, line)) do
            ["#{path}:#{line_number}: #{line}"]
          else
            []
          end
        end)
      end)

    assert offenders == []
  end

  test "selected encoders and middleware do not consume string-key internal content blocks" do
    root = Path.expand("../..", __DIR__)

    checks = [
      {"lib/beam_weaver/open_ai/messages/request.ex", @string_content_block_input},
      {"lib/beam_weaver/open_ai/chat_completions/messages/request.ex", @string_content_block_input},
      {"lib/beam_weaver/core/messages/open_ai.ex", @string_content_block_input},
      {"lib/beam_weaver/agent/middleware/prompt_caching.ex", @middleware_string_content},
      {"lib/beam_weaver/agent/middleware/offload.ex", @middleware_string_content}
    ]

    offenders =
      Enum.flat_map(checks, fn {path, regex} ->
        root
        |> Path.join(path)
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_number} ->
          if Regex.match?(regex, line), do: ["#{path}:#{line_number}: #{line}"], else: []
        end)
      end)

    assert offenders == []
  end
end
