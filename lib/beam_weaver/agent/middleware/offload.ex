defmodule BeamWeaver.Agent.Middleware.Offload do
  @moduledoc false

  alias BeamWeaver.Core.Message

  @preview_lines 5

  @too_large_tool_msg """
  Tool result too large, the result of this tool call %{tool_call_id} was saved in the filesystem at this path: %{file_path}

  You can read the result from the filesystem by using the read_file tool, but make sure to only read part of the result at a time.

  You can do this by specifying an offset and limit in the read_file tool call. For example, to read the first 100 lines, you can use the read_file tool with offset=0 and limit=100.

  Here is a preview showing the head and tail of the result (lines of the form `... [N lines truncated] ...` indicate omitted lines in the middle of the content):

  %{content_sample}
  """

  def tool_result_notice(tool_call_id, file_path, content) do
    format_notice(@too_large_tool_msg,
      tool_call_id: tool_call_id,
      file_path: file_path,
      content_sample: content_preview(content)
    )
  end

  def sanitize_tool_call_id(id) do
    id
    |> to_string()
    |> String.replace(".", "_")
    |> String.replace("/", "_")
    |> String.replace("\\", "_")
  end

  def format_notice(template, values) when is_binary(template) do
    Enum.reduce(values, template, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  def content_preview(content) do
    lines = split_lines(content)

    if length(lines) <= 2 * @preview_lines do
      lines
      |> Enum.map(&String.slice(&1, 0, 1000))
      |> numbered_lines(1)
    else
      head = lines |> Enum.take(@preview_lines) |> Enum.map(&String.slice(&1, 0, 1000))
      tail = lines |> Enum.take(-@preview_lines) |> Enum.map(&String.slice(&1, 0, 1000))

      numbered_lines(head, 1) <>
        "\n... [#{length(lines) - 2 * @preview_lines} lines truncated] ...\n" <>
        numbered_lines(tail, length(lines) - @preview_lines + 1)
    end
  end

  def evicted_content(%Message{content: content}, replacement) when is_list(content) do
    media_blocks = Enum.reject(content, &text_block?/1)

    if media_blocks == [] do
      replacement
    else
      [%{type: :text, text: replacement} | media_blocks]
    end
  end

  def evicted_content(_message, replacement), do: replacement

  def merge_files_update(nil, files_update), do: files_update
  def merge_files_update(files_update, nil), do: files_update

  def merge_files_update(left, right), do: Map.merge(left, right)

  def maybe_put_state_files(opts, _state_key, nil), do: opts

  def maybe_put_state_files(opts, state_key, files_update) when is_map(files_update) do
    state = Keyword.get(opts, :state, %{}) || %{}
    Keyword.put(opts, :state, Map.put(state, state_key, files_update))
  end

  defp split_lines(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n")
    |> then(fn
      [] -> []
      lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    end)
  end

  defp numbered_lines(lines, start) do
    lines
    |> Enum.with_index(start)
    |> Enum.map_join("\n", fn {line, line_number} ->
      String.pad_leading(to_string(line_number), 6) <> "\t" <> line
    end)
  end

  defp text_block?(text) when is_binary(text), do: true
  defp text_block?(%{type: :text}), do: true
  defp text_block?(%{type: :plain_text}), do: true
  defp text_block?(%{text: text}) when is_binary(text), do: true
  defp text_block?(_block), do: false
end
