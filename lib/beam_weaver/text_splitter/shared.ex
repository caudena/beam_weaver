defmodule BeamWeaver.TextSplitter.Shared do
  @moduledoc false

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Tokenizer

  @default_separators ["\n\n", "\n", " ", ""]

  def common_fields do
    [
      chunk_size: 1_000,
      chunk_overlap: 200,
      separators: @default_separators,
      keep_separator: false,
      strip_whitespace: true,
      add_start_index: false,
      length_function: nil,
      separator_regex?: false
    ]
  end

  def normalize_opts(opts, defaults \\ []) do
    opts = normalize_aliases(opts)

    common_fields()
    |> Keyword.merge(defaults)
    |> Keyword.merge(opts)
  end

  defp maybe_put_separator(opts) do
    case Keyword.fetch(opts, :separator) do
      {:ok, separator} ->
        opts |> Keyword.delete(:separator) |> Keyword.put(:separators, [separator])

      :error ->
        opts
    end
  end

  defp normalize_aliases(opts) do
    opts
    |> maybe_put_separator()
    |> maybe_put_regex_flag()
    |> maybe_put_max_chunk_size()
  end

  defp maybe_put_regex_flag(opts) do
    case Keyword.fetch(opts, :is_separator_regex) do
      {:ok, value} ->
        opts |> Keyword.delete(:is_separator_regex) |> Keyword.put(:separator_regex?, value)

      :error ->
        opts
    end
  end

  defp maybe_put_max_chunk_size(opts) do
    case Keyword.fetch(opts, :max_chunk_size) do
      {:ok, size} ->
        opts |> Keyword.delete(:max_chunk_size) |> Keyword.put(:chunk_size, size)

      :error ->
        opts
    end
  end

  def validate(splitter) do
    size = Map.get(splitter, :chunk_size)
    overlap = Map.get(splitter, :chunk_overlap, 0)
    keep_separator = Map.get(splitter, :keep_separator, false)

    cond do
      not is_integer(size) or size <= 0 ->
        {:error, Error.new(:invalid_text_splitter, "chunk_size must be a positive integer")}

      not is_integer(overlap) or overlap < 0 ->
        {:error, Error.new(:invalid_text_splitter, "chunk_overlap must be a non-negative integer")}

      overlap > size ->
        {:error,
         Error.new(
           :invalid_text_splitter,
           "chunk_overlap must be smaller than or equal to chunk_size"
         )}

      keep_separator not in [false, true, :start, :end] ->
        {:error,
         Error.new(
           :invalid_text_splitter,
           keep_separator_error(keep_separator)
         )}

      true ->
        :ok
    end
  end

  defp keep_separator_error(value) when is_binary(value) do
    suffix =
      case value do
        "start" -> "; use :start"
        "end" -> "; use :end"
        _other -> ""
      end

    "keep_separator must be false, true, :start, or :end, got #{inspect(value)}#{suffix}"
  end

  defp keep_separator_error(value),
    do: "keep_separator must be false, true, :start, or :end, got #{inspect(value)}"

  def split_text(splitter, text) when is_binary(text) do
    case validate(splitter) do
      :ok ->
        recursive_split(text, splitter, Map.get(splitter, :separators, @default_separators))
        |> merge_splits(splitter)
        |> reject_empty()

      {:error, error} ->
        raise ArgumentError, error.message
    end
  end

  def token_split_text(splitter, text) when is_binary(text) do
    tokenizer = Map.get(splitter, :tokenizer) || %BeamWeaver.Tokenizer.Approximate{}

    case validate(splitter) do
      :ok ->
        case Tokenizer.split_tokens(tokenizer, text) do
          {:ok, tokens} ->
            chunk_tokens(tokens, splitter.chunk_size, splitter.chunk_overlap)
            |> Enum.map(&Enum.join/1)
            |> maybe_strip(splitter)
            |> reject_empty()

          {:error, error} ->
            raise ArgumentError, error.message
        end

      {:error, error} ->
        raise ArgumentError, error.message
    end
  end

  def split_document(splitter, %Document{} = document) do
    splitter
    |> split_text(document.content)
    |> chunks_to_documents(document, Map.get(splitter, :add_start_index, false))
  end

  def token_split_document(splitter, %Document{} = document) do
    splitter
    |> token_split_text(document.content)
    |> chunks_to_documents(document, Map.get(splitter, :add_start_index, false))
  end

  def chunks_to_documents(chunks, %Document{} = document, add_start_index?) do
    {_offset, docs} =
      Enum.reduce(chunks, {0, []}, fn chunk, {offset, acc} ->
        {start, next_offset} = start_index(document.content, chunk, offset)

        metadata =
          if add_start_index?,
            do: Map.put(document.metadata, :start_index, start),
            else: document.metadata

        {next_offset, [Document.new!(chunk, id: document.id, metadata: metadata) | acc]}
      end)

    Enum.reverse(docs)
  end

  def strip_markup(text) do
    text
    |> String.replace(~r/<(script|style)[^>]*>.*?<\/\1>/isu, " ")
    |> String.replace(~r/<[^>]*>/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp recursive_split(text, splitter, _separators) when byte_size(text) <= splitter.chunk_size,
    do: [text]

  defp recursive_split(text, splitter, []), do: fixed_chunks(text, splitter.chunk_size)

  defp recursive_split(text, splitter, [separator | rest]) do
    pieces = split_by_separator(text, separator, splitter)

    if Enum.any?(pieces, &(measure(splitter, &1) > splitter.chunk_size)) and rest != [] do
      Enum.flat_map(pieces, &recursive_split(&1, splitter, rest))
    else
      pieces
    end
  end

  defp split_by_separator(text, "", _splitter), do: String.graphemes(text)

  defp split_by_separator(text, separator, splitter) do
    if Map.get(splitter, :separator_regex?, false) do
      split_regex(text, separator, splitter)
    else
      split_string(text, separator, splitter)
    end
  end

  defp split_string(text, separator, splitter) do
    pieces = String.split(text, separator, trim: false)
    seps = List.duplicate(separator, max(length(pieces) - 1, 0))
    keep_separator(pieces, seps, splitter)
  end

  defp split_regex(text, separator, splitter) do
    regex = Regex.compile!(separator)
    {pieces, seps} = regex_pieces_and_separators(regex, text)
    keep_separator(pieces, seps, splitter)
  end

  defp keep_separator(pieces, seps, splitter) do
    mode = keep_separator_mode(Map.get(splitter, :keep_separator, false))

    pieces
    |> Enum.with_index()
    |> Enum.map(fn {piece, index} ->
      cond do
        mode == :end and index < length(pieces) - 1 ->
          piece <> Enum.at(seps, index, "")

        mode == :start and index > 0 ->
          Enum.at(seps, index - 1, "") <> piece

        true ->
          piece
      end
    end)
    |> maybe_strip(splitter)
  end

  defp keep_separator_mode(true), do: :start
  defp keep_separator_mode(:start), do: :start
  defp keep_separator_mode(:end), do: :end
  defp keep_separator_mode(_other), do: false

  defp regex_pieces_and_separators(regex, text) do
    tokens = Regex.split(regex, text, include_captures: true, trim: false)

    {pieces, seps, _expect_piece?} =
      Enum.reduce(tokens, {[], [], true}, fn token, {pieces, seps, expect_piece?} ->
        if expect_piece? do
          {[token | pieces], seps, false}
        else
          {pieces, [token | seps], true}
        end
      end)

    {Enum.reverse(pieces), Enum.reverse(seps)}
  end

  defp merge_splits(pieces, splitter) do
    pieces
    |> maybe_strip(splitter)
    |> Enum.reduce({[], [], 0}, fn piece, {chunks, current, total} ->
      append_split(piece, chunks, current, total, splitter, merge_separator(splitter))
    end)
    |> flush_current(splitter, merge_separator(splitter))
    |> Enum.reverse()
  end

  defp append_split(piece, chunks, current, total, splitter, separator) do
    piece_length = measure(splitter, piece)
    separator_length = if current == [], do: 0, else: measure(splitter, separator)

    {chunks, current, total} =
      if total + piece_length + separator_length > splitter.chunk_size and current != [] do
        flushed = join_current(current, separator, splitter)

        {trimmed_current, trimmed_total} =
          trim_to_overlap(current, total, splitter, separator, piece_length)

        {[flushed | chunks], trimmed_current, trimmed_total}
      else
        {chunks, current, total}
      end

    separator_length = if current == [], do: 0, else: measure(splitter, separator)
    {chunks, current ++ [piece], total + piece_length + separator_length}
  end

  defp flush_current({chunks, [], _total}, _splitter, _separator), do: chunks

  defp flush_current({chunks, current, _total}, splitter, separator),
    do: [join_current(current, separator, splitter) | chunks]

  defp trim_to_overlap(current, total, splitter, separator, next_piece_length) do
    next_separator_length = if current == [], do: 0, else: measure(splitter, separator)

    cond do
      total <= splitter.chunk_overlap and
          total + next_piece_length + next_separator_length <= splitter.chunk_size ->
        {current, total}

      current == [] ->
        {current, total}

      true ->
        [first | rest] = current
        separator_length = if rest == [], do: 0, else: measure(splitter, separator)
        next_total = total - measure(splitter, first) - separator_length
        trim_to_overlap(rest, max(next_total, 0), splitter, separator, next_piece_length)
    end
  end

  defp join_current(current, separator, splitter),
    do: current |> Enum.join(separator) |> then(&maybe_strip([&1], splitter)) |> hd()

  defp merge_separator(splitter) do
    if keep_separator_mode(Map.get(splitter, :keep_separator, false)) do
      separators = Map.get(splitter, :separators, @default_separators)

      cond do
        Map.get(splitter, :separator_regex?, false) -> ""
        " " in separators -> " "
        true -> ""
      end
    else
      case Map.get(splitter, :separators, @default_separators) do
        [separator | _rest] when is_binary(separator) -> separator
        _other -> ""
      end
    end
  end

  defp chunk_tokens(tokens, chunk_size, overlap) do
    step = max(chunk_size - overlap, 1)

    tokens
    |> Stream.unfold(fn
      [] ->
        nil

      rest ->
        chunk = Enum.take(rest, chunk_size)
        next = if length(rest) <= chunk_size, do: [], else: Enum.drop(rest, step)
        {chunk, next}
    end)
    |> Enum.to_list()
  end

  defp fixed_chunks(text, chunk_size) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(&Enum.join/1)
  end

  defp maybe_strip(pieces, splitter) do
    if Map.get(splitter, :strip_whitespace, true),
      do: Enum.map(pieces, &String.trim/1),
      else: pieces
  end

  defp reject_empty(pieces), do: Enum.reject(pieces, &(&1 == ""))

  defp measure(%{length_function: fun}, text) when is_function(fun, 1), do: fun.(text)
  defp measure(_splitter, text), do: String.length(text)

  defp start_index(text, chunk, offset) do
    search =
      text
      |> binary_part(min(offset, byte_size(text)), max(byte_size(text) - offset, 0))

    case :binary.match(search, chunk) do
      {index, length} ->
        byte_start = offset + index
        {char_index(text, byte_start), byte_start + length}

      :nomatch ->
        case :binary.match(text, chunk) do
          {index, length} -> {char_index(text, index), index + length}
          :nomatch -> {nil, offset}
        end
    end
  end

  defp char_index(text, byte_offset), do: String.length(binary_part(text, 0, byte_offset))
end
