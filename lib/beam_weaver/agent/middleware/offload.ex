defmodule BeamWeaver.Agent.Middleware.Offload do
  @moduledoc false

  alias BeamWeaver.Core.Message

  @preview_lines 5
  @preview_line_chars 1_000

  @too_large_tool_msg """
  Tool result too large, the result of this tool call %{tool_call_id} was saved in the filesystem at this path: %{file_path}

  %{how_to_read}Here is a preview showing the head and tail of the result%{preview_notes}:

  %{content_sample}
  """

  @read_saved_result """
  You can read the result from the filesystem by using the read_file tool, but make sure to only read part of the result at a time.

  You can do this by specifying an offset and limit in the read_file tool call. For example, to read the first 100 lines, you can use the read_file tool with offset=0 and limit=100.

  """

  # The notice that replaces a saved tool result. It tells the model to read
  # the result with `read_file` only when `read_file?`, that is when the
  # model is offered that tool.
  def tool_result_notice(tool_call_id, file_path, content, read_file?) do
    {sample, notes} = preview(content)

    format_notice(@too_large_tool_msg,
      how_to_read: if(read_file?, do: @read_saved_result, else: ""),
      tool_call_id: tool_call_id,
      file_path: file_path,
      preview_notes: notes,
      content_sample: sample
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

  # The numbered head and tail lines of `content`, and a note on what they
  # leave out, so the model doesn't take the preview for the whole content.
  def preview(content) do
    lines = split_lines(content)
    omitted = length(lines) - 2 * @preview_lines

    shown =
      if omitted > 0, do: Enum.take(lines, @preview_lines) ++ Enum.take(lines, -@preview_lines), else: lines

    clipped? = Enum.any?(shown, &(String.length(&1) > @preview_line_chars))
    {sample(lines, omitted), preview_notes(omitted > 0, clipped?)}
  end

  defp sample(lines, omitted) when omitted <= 0, do: lines |> Enum.map(&clip/1) |> numbered_lines(1)

  defp sample(lines, omitted) do
    head = lines |> Enum.take(@preview_lines) |> Enum.map(&clip/1)
    tail = lines |> Enum.take(-@preview_lines) |> Enum.map(&clip/1)

    numbered_lines(head, 1) <>
      "\n... [#{omitted} lines truncated] ...\n" <>
      numbered_lines(tail, length(lines) - @preview_lines + 1)
  end

  defp preview_notes(false, false), do: ""

  defp preview_notes(omitted?, clipped?) do
    notes = [
      omitted? && "lines of the form `... [N lines truncated] ...` indicate omitted lines in the middle of the content",
      clipped? && "lines longer than 1,000 characters are cut off after 1,000 characters"
    ]

    " (" <> (notes |> Enum.filter(&is_binary/1) |> Enum.join("; ")) <> ")"
  end

  defp clip(line), do: String.slice(line, 0, @preview_line_chars)

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

  def maybe_put_state_files(opts, state_key, files_update) when is_map(files_update),
    do: Keyword.put(opts, :state, put_files_update(Keyword.get(opts, :state, %{}) || %{}, state_key, files_update))

  # `state` with the files a backend changed merged into its files, as the
  # files channel merges them.
  def put_files_update(state, _state_key, nil), do: state

  def put_files_update(state, state_key, files_update) when is_map(files_update),
    do: Map.update(state, state_key, files_update, &Map.merge(&1 || %{}, files_update))

  defp split_lines(content) do
    lines = String.split(content, ["\r\n", "\r", "\n"])
    if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
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
