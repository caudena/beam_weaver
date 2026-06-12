defmodule BeamWeaver.Agent.Middleware.Offload do
  @moduledoc false

  alias BeamWeaver.Core.Message

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

  def content_preview(content, head_lines \\ 5, tail_lines \\ 5) do
    lines = split_lines(content)

    if length(lines) <= head_lines + tail_lines do
      lines
      |> Enum.map(&String.slice(&1, 0, 1000))
      |> numbered_lines(1)
    else
      head = lines |> Enum.take(head_lines) |> Enum.map(&String.slice(&1, 0, 1000))
      tail = lines |> Enum.take(-tail_lines) |> Enum.map(&String.slice(&1, 0, 1000))
      omitted = length(lines) - head_lines - tail_lines
      tail_start = length(lines) - tail_lines + 1

      numbered_lines(head, 1) <>
        "\n... [#{omitted} lines truncated] ...\n" <>
        numbered_lines(tail, tail_start)
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

  def merge_files_update(left, right) when is_map(left) and is_map(right),
    do: Map.merge(left, right)

  def merge_files_update(_left, right), do: right

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
