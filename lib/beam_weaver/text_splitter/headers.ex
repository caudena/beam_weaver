defmodule BeamWeaver.TextSplitter.MarkdownHeaders do
  @moduledoc false

  alias BeamWeaver.Core.Document
  alias BeamWeaver.TextSplitter.Shared

  defstruct headers: [
              {"#", "Header 1"},
              {"##", "Header 2"},
              {"###", "Header 3"},
              {"####", "Header 4"},
              {"#####", "Header 5"},
              {"######", "Header 6"}
            ],
            return_each_line: false,
            strip_whitespace: true,
            strip_headers?: true

  def new(opts \\ []), do: struct(__MODULE__, opts)

  def split_text(%__MODULE__{}, text), do: String.split(text, "\n", trim: true)

  def split_document(%__MODULE__{} = splitter, %Document{} = document) do
    header_map = Map.new(splitter.headers)

    {current, section, docs, _fence} =
      document.content
      |> String.split("\n")
      |> Enum.reduce({%{}, [], [], nil}, fn line, {metadata, lines, docs, fence} ->
        next_fence = markdown_fence(line, fence)

        case if(fence, do: nil, else: markdown_header(line, header_map)) do
          nil ->
            {metadata, [line | lines], docs, next_fence}

          {level, title} ->
            docs = flush_markdown_section(document, splitter, metadata, lines, docs)

            metadata =
              metadata
              |> drop_deeper_headers(level, header_map)
              |> Map.put(header_map[level], title)

            lines = if splitter.strip_headers?, do: [], else: [line]

            {metadata, lines, docs, next_fence}
        end
      end)

    flush_markdown_section(document, splitter, current, section, docs)
    |> Enum.reverse()
  end

  defp markdown_fence(line, nil) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "```") -> "```"
      String.starts_with?(trimmed, "~~~") -> "~~~"
      true -> nil
    end
  end

  defp markdown_fence(line, fence) do
    if String.trim_leading(line) |> String.starts_with?(fence),
      do: nil,
      else: fence
  end

  defp markdown_header(line, header_map) do
    line = String.trim_leading(line)

    Enum.find_value(Map.keys(header_map) |> Enum.sort_by(&String.length/1, :desc), fn prefix ->
      marker = prefix <> " "

      if String.starts_with?(line, marker),
        do: {prefix, String.trim_leading(line, marker) |> String.trim()},
        else: nil
    end)
  end

  defp flush_markdown_section(_document, _splitter, _metadata, [], docs), do: docs

  defp flush_markdown_section(document, splitter, metadata, lines, docs) do
    content =
      lines
      |> Enum.reverse()
      |> Enum.join("\n")
      |> maybe_trim(splitter)

    if content == "" do
      docs
    else
      [Document.new!(content, metadata: Map.merge(document.metadata, metadata)) | docs]
    end
  end

  defp drop_deeper_headers(metadata, level, header_map) do
    current_len = String.length(level)

    Enum.reduce(header_map, metadata, fn {prefix, name}, acc ->
      if String.length(prefix) >= current_len, do: Map.delete(acc, name), else: acc
    end)
  end

  defp maybe_trim(text, %{strip_whitespace: true}), do: String.trim(text)
  defp maybe_trim(text, _splitter), do: text
end

defmodule BeamWeaver.TextSplitter.HTMLHeaders do
  @moduledoc false

  alias BeamWeaver.Core.Document
  alias BeamWeaver.TextSplitter.Shared

  defstruct headers: [
              {"h1", "Header 1"},
              {"h2", "Header 2"},
              {"h3", "Header 3"},
              {"h4", "Header 4"},
              {"h5", "Header 5"},
              {"h6", "Header 6"}
            ],
            strip_whitespace: true

  def new(opts \\ []), do: struct(__MODULE__, opts)

  def split_text(%__MODULE__{}, text), do: [Shared.strip_markup(text)]

  def split_document(%__MODULE__{} = splitter, %Document{} = document) do
    header_map = Map.new(splitter.headers)
    regex = ~r/<(h[1-6])[^>]*>(.*?)<\/\1>/is
    content = promote_font_size_headers(document.content)
    pieces = Regex.split(regex, content, include_captures: true, trim: false)

    {metadata, buffer, docs} =
      Enum.reduce(pieces, {%{}, [], []}, fn piece, {metadata, buffer, docs} ->
        case Regex.run(regex, piece) do
          [_, tag, title] ->
            docs = flush_html_section(document, splitter, metadata, buffer, docs)

            tag = String.downcase(tag)

            metadata =
              metadata
              |> drop_deeper_headers(tag, header_map)
              |> Map.put(header_map[tag], Shared.strip_markup(title))

            {metadata, [], docs}

          _other ->
            {metadata, [piece | buffer], docs}
        end
      end)

    flush_html_section(document, splitter, metadata, buffer, docs)
    |> Enum.reverse()
  end

  defp flush_html_section(_document, _splitter, _metadata, [], docs), do: docs

  defp flush_html_section(document, splitter, metadata, buffer, docs) do
    content =
      buffer
      |> Enum.reverse()
      |> Enum.join("")
      |> Shared.strip_markup()
      |> maybe_trim(splitter)

    if content == "" do
      docs
    else
      [Document.new!(content, metadata: Map.merge(document.metadata, metadata)) | docs]
    end
  end

  defp maybe_trim(text, %{strip_whitespace: true}), do: String.trim(text)
  defp maybe_trim(text, _splitter), do: text

  defp drop_deeper_headers(metadata, tag, header_map) do
    current_level = header_level(tag)

    Enum.reduce(header_map, metadata, fn {header_tag, name}, acc ->
      if header_level(header_tag) >= current_level, do: Map.delete(acc, name), else: acc
    end)
  end

  defp header_level("h" <> level) do
    case Integer.parse(level) do
      {integer, ""} -> integer
      _other -> 6
    end
  end

  defp promote_font_size_headers(html) do
    regex =
      ~r/<(p|div|span)([^>]*)style=["'][^"']*font-size\s*:\s*(\d+(?:\.\d+)?)px[^"']*["']([^>]*)>(.*?)<\/\1>/is

    sizes =
      regex
      |> Regex.scan(html)
      |> Enum.map(fn [_all, _tag, _attrs_before, size, _attrs_after, _inner] ->
        {number, _rest} = Float.parse(size)
        number
      end)
      |> Enum.uniq()
      |> Enum.sort(:desc)
      |> Enum.with_index(1)
      |> Map.new()

    Regex.replace(regex, html, fn _all, _tag, _attrs_before, size, _attrs_after, inner ->
      {number, _rest} = Float.parse(size)
      level = Map.get(sizes, number, 6) |> min(6)
      "<h#{level}>#{inner}</h#{level}>"
    end)
  end
end
