defmodule BeamWeaver.Filesystem.Format do
  @moduledoc false

  @max_line_length 5_000
  @line_number_width 6
  @tool_result_token_limit 20_000
  @truncation_guidance "... [results truncated, try being more specific with your parameters]"

  def max_line_length, do: @max_line_length
  def line_number_width, do: @line_number_width
  def tool_result_token_limit, do: @tool_result_token_limit
  def truncation_guidance, do: @truncation_guidance

  def count_occurrences(_content, ""), do: 0
  def count_occurrences(content, needle), do: length(:binary.matches(content, needle))

  def perform_string_replacement(content, old, new, opts \\ []) do
    replace_all? = Keyword.get(opts, :replace_all, false)
    occurrences = count_occurrences(content, old)

    cond do
      occurrences == 0 ->
        {:error, "string not found", 0}

      occurrences > 1 and not replace_all? ->
        {:error, "multiple occurrences", occurrences}

      replace_all? ->
        {:ok, String.replace(content, old, new), occurrences}

      true ->
        {:ok, String.replace(content, old, new, global: false), 1}
    end
  end

  def format_content_with_line_numbers(content, opts \\ []) do
    start = Keyword.get(opts, :start, 1)
    width = Keyword.get(opts, :width, @line_number_width)
    max_line_length = Keyword.get(opts, :max_line_length, @max_line_length)

    content
    |> String.split("\n")
    |> Enum.with_index(start)
    |> Enum.flat_map(fn {line, line_number} ->
      chunk_line(line, line_number, width, max_line_length)
    end)
    |> Enum.join("\n")
  end

  def truncate_if_too_long(result), do: truncate_if_too_long(result, @tool_result_token_limit * 4)

  def truncate_if_too_long(result, max_bytes) when is_list(result) do
    total = result |> Enum.map(&String.length(to_string(&1))) |> Enum.sum()

    if total > max_bytes do
      keep = max(div(length(result) * max_bytes, max(total, 1)), 0)
      Enum.take(result, keep) ++ [@truncation_guidance]
    else
      result
    end
  end

  def truncate_if_too_long(content, max_bytes), do: truncate_if_too_long(content, max_bytes, "")

  def truncate_if_too_long(content, :unlimited, _guidance), do: {content, false}

  def truncate_if_too_long(content, max_bytes, guidance)
      when is_binary(content) and is_integer(max_bytes) and max_bytes > 0 do
    if byte_size(content) > max_bytes do
      suffix =
        case guidance do
          "" -> "\n\n... truncated at #{max_bytes} bytes."
          guidance -> "\n\n... truncated at #{max_bytes} bytes. #{guidance}"
        end

      {binary_part(content, 0, max_bytes) <> suffix, true}
    else
      {content, false}
    end
  end

  def truncate_if_too_long(content, _max_bytes, _guidance), do: {content, false}

  defp chunk_line(line, line_number, width, max_line_length) do
    if String.length(line) <= max_line_length do
      [String.pad_leading(to_string(line_number), width) <> "\t" <> line]
    else
      line
      |> chunk_binary(max_line_length)
      |> Enum.with_index()
      |> Enum.map(fn
        {chunk, 0} ->
          String.pad_leading(to_string(line_number), width) <> "\t" <> chunk

        {chunk, index} ->
          String.pad_leading("#{line_number}.#{index}", width) <> "\t" <> chunk
      end)
    end
  end

  defp chunk_binary("", _size), do: [""]

  defp chunk_binary(binary, size) do
    do_chunk_binary(binary, size, [])
  end

  defp do_chunk_binary("", _size, chunks), do: Enum.reverse(chunks)

  defp do_chunk_binary(binary, size, chunks) do
    case String.split_at(binary, size) do
      {chunk, ""} -> Enum.reverse([chunk | chunks])
      {chunk, rest} -> do_chunk_binary(rest, size, [chunk | chunks])
    end
  end
end
