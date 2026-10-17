defmodule BeamWeaver.TextSplitter.MarkdownSyntax do
  @moduledoc false

  alias BeamWeaver.Core.Document

  defstruct headers: [
              {"#", "Header 1"},
              {"##", "Header 2"},
              {"###", "Header 3"},
              {"####", "Header 4"},
              {"#####", "Header 5"},
              {"######", "Header 6"}
            ],
            return_each_line: false,
            strip_headers?: true,
            chunk_size: 1_000,
            chunk_overlap: 0

  def new(opts), do: struct(__MODULE__, opts)

  def split_text(%__MODULE__{} = splitter, text) when is_binary(text) do
    splitter
    |> split_document(Document.new!(text))
    |> Enum.map(& &1.content)
  end

  def split_document(%__MODULE__{} = splitter, %Document{} = document) do
    {chunks, current, headers} =
      document.content
      |> markdown_lines()
      |> consume_markdown_lines(splitter, {[], "", []}, Map.new(splitter.headers))

    # Every chunk keeps the document's metadata, under its own header keys.
    chunks
    |> complete_markdown_chunk(splitter, current, headers)
    |> Enum.reverse()
    |> Enum.map(&%{&1 | metadata: Map.merge(document.metadata, &1.metadata)})
    |> maybe_lines(splitter)
  end

  defp consume_markdown_lines([], _splitter, state, _header_names), do: state

  defp consume_markdown_lines([line | rest], splitter, {chunks, current, headers}, header_names) do
    cond do
      header = markdown_header(line, header_names) ->
        chunks = complete_markdown_chunk(chunks, splitter, current, headers)
        {depth, title} = header
        headers = resolve_markdown_headers(headers, depth, title)
        current = if splitter.strip_headers?, do: "", else: line
        consume_markdown_lines(rest, splitter, {chunks, current, headers}, header_names)

      code = markdown_code_fence(line) ->
        chunks = complete_markdown_chunk(chunks, splitter, current, headers)
        {code_chunk, rest} = take_code_chunk(rest, line, code.marker)
        metadata = headers_to_metadata(headers, splitter) |> Map.put("Code", code.language)
        chunks = append_markdown_doc(chunks, code_chunk, metadata)
        consume_markdown_lines(rest, splitter, {chunks, "", headers}, header_names)

      markdown_horizontal_rule?(line) ->
        chunks = complete_markdown_chunk(chunks, splitter, current, headers)
        consume_markdown_lines(rest, splitter, {chunks, "", headers}, header_names)

      true ->
        consume_markdown_lines(rest, splitter, {chunks, current <> line, headers}, header_names)
    end
  end

  defp markdown_lines(text) do
    ~r/[^\n]*\n|[^\n]+/u
    |> Regex.scan(text)
    |> Enum.map(fn [line] -> line end)
  end

  defp markdown_header(line, header_names) do
    case Regex.run(~r/^(\#{1,6}) (.*?)(?:\n)?$/u, line) do
      [_, marker, title] when is_map_key(header_names, marker) ->
        {String.length(marker), title}

      _other ->
        nil
    end
  end

  defp markdown_code_fence(line) do
    case Regex.run(~r/^(```|~~~)(.*)/u, line) do
      [_, marker, language] -> %{marker: marker, language: String.trim(language)}
      _other -> nil
    end
  end

  defp take_code_chunk([], chunk, _marker), do: {chunk, []}

  defp take_code_chunk([line | rest], chunk, marker) do
    chunk = chunk <> line

    if String.starts_with?(line, marker),
      do: {chunk, rest},
      else: take_code_chunk(rest, chunk, marker)
  end

  defp markdown_horizontal_rule?(line) do
    Regex.match?(~r/^(\*\*\*+|---+|___+)\s*\n?$/u, line)
  end

  defp resolve_markdown_headers(headers, depth, title) do
    headers
    |> Enum.reject(fn {existing_depth, _title} -> existing_depth >= depth end)
    |> Kernel.++([{depth, title}])
  end

  defp complete_markdown_chunk(chunks, splitter, content, headers) do
    if String.trim(content) == "" do
      chunks
    else
      append_markdown_doc(chunks, content, headers_to_metadata(headers, splitter))
    end
  end

  defp append_markdown_doc(chunks, content, metadata),
    do: [Document.new!(content, metadata: metadata) | chunks]

  defp headers_to_metadata(headers, splitter) do
    header_names = Map.new(splitter.headers)

    Map.new(headers, fn {depth, title} ->
      {Map.fetch!(header_names, String.duplicate("#", depth)), title}
    end)
  end

  defp maybe_lines(docs, %{return_each_line: false}), do: docs

  defp maybe_lines(docs, %{return_each_line: true}) do
    Enum.flat_map(docs, fn %Document{} = doc ->
      doc.content
      |> String.split("\n")
      |> Enum.reject(&(&1 == "" or String.trim(&1) == ""))
      |> Enum.map(&Document.new!(&1, metadata: doc.metadata))
    end)
  end
end
