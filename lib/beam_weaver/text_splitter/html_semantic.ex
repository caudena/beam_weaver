defmodule BeamWeaver.TextSplitter.HTMLSemantic do
  @moduledoc false
  alias BeamWeaver.Core.Document
  alias BeamWeaver.TextSplitter.RecursiveCharacter

  defstruct chunk_size: 1_000,
            chunk_overlap: 0,
            headers: [],
            separators: nil,
            elements_to_preserve: [],
            preserve_links: false,
            preserve_images: false,
            preserve_videos: false,
            preserve_audio: false,
            custom_handlers: %{},
            stopword_removal: false,
            stopwords: nil,
            normalize_text: false,
            external_metadata: %{},
            allowlist_tags: nil,
            denylist_tags: nil,
            preserve_parent_metadata: false,
            keep_separator: true,
            strip_whitespace: true,
            separator_regex?: false,
            add_start_index: false,
            length_function: nil

  def new(opts \\ []) do
    opts =
      opts
      |> normalize_alias(:headers_to_split_on, :headers)
      |> normalize_alias(:max_chunk_size, :chunk_size)

    struct(__MODULE__, opts)
  end

  def split_text(%__MODULE__{} = splitter, text) when is_binary(text) do
    splitter
    |> split_html(text, %{})
    |> Enum.map(& &1.content)
  end

  def split_document(%__MODULE__{} = splitter, %Document{} = document) do
    parent_metadata =
      if splitter.preserve_parent_metadata,
        do: document.metadata,
        else: %{}

    splitter
    |> split_html(document.content, parent_metadata)
    |> Enum.map(&%{&1 | id: document.id})
  end

  defp split_html(%__MODULE__{} = splitter, html, parent_metadata) do
    html =
      html
      |> strip_unsafe()
      |> replace_custom_handlers(splitter)
      |> replace_media(splitter)
      |> replace_links(splitter)
      |> filter_tags(splitter)

    html
    |> sections(splitter)
    |> Enum.flat_map(fn {metadata, content} ->
      content = html_text(content, splitter)
      metadata = parent_metadata |> Map.merge(metadata) |> Map.merge(splitter.external_metadata)
      create_docs(splitter, content, metadata)
    end)
  end

  defp sections(html, %{headers: []}), do: [{%{}, html}]

  defp sections(html, splitter) do
    header_tags = splitter.headers |> Enum.map(&elem(&1, 0)) |> Enum.map(&String.downcase/1)
    header_names = Map.new(splitter.headers, fn {tag, name} -> {String.downcase(tag), name} end)
    regex = Regex.compile!("<(#{Enum.join(header_tags, "|")})(?:\\s[^>]*)?>(.*?)</\\1>", "is")
    matches = Regex.scan(regex, html, return: :index)

    {cursor, header_state, docs} =
      Enum.reduce(matches, {0, [], []}, fn [
                                             {start, length},
                                             {tag_start, tag_length},
                                             {inner_start, inner_length}
                                           ],
                                           {cursor, headers, docs} ->
        before = binary_part(html, cursor, max(start - cursor, 0))
        docs = maybe_add_section(docs, headers, before, header_names)
        tag = html |> binary_part(tag_start, tag_length) |> String.downcase()

        title =
          html
          |> binary_part(inner_start, inner_length)
          |> html_text(%{splitter | normalize_text: false})

        headers = resolve_html_headers(headers, tag, title, header_names)
        {start + length, headers, docs}
      end)

    rest = binary_part(html, cursor, byte_size(html) - cursor)

    docs
    |> maybe_add_section(header_state, rest, header_names)
    |> Enum.reverse()
  end

  defp maybe_add_section(docs, _headers, content, _header_names)
       when content == "" or is_nil(content),
       do: docs

  defp maybe_add_section(docs, headers, content, header_names) do
    if String.trim(html_text(content, %__MODULE__{})) == "" do
      docs
    else
      [{html_header_metadata(headers, header_names), content} | docs]
    end
  end

  defp resolve_html_headers(headers, tag, title, header_names) do
    level = html_level(tag)

    headers
    |> Enum.reject(fn {existing_tag, _title} -> html_level(existing_tag) >= level end)
    |> Kernel.++([{tag, title}])
    |> Enum.filter(fn {header_tag, _title} -> Map.has_key?(header_names, header_tag) end)
  end

  defp html_header_metadata(headers, header_names) do
    Map.new(headers, fn {tag, title} -> {Map.fetch!(header_names, tag), title} end)
  end

  defp html_level("h" <> level) do
    case Integer.parse(level) do
      {integer, ""} -> integer
      _other -> 999
    end
  end

  defp strip_unsafe(html) do
    html
    |> String.replace(~r/<!--.*?-->/su, " ")
    |> String.replace(~r/<(script|style)[^>]*>.*?<\/\1>/isu, " ")
  end

  defp replace_custom_handlers(html, %{custom_handlers: handlers}) when map_size(handlers) == 0,
    do: html

  defp replace_custom_handlers(html, %{custom_handlers: handlers}) do
    Enum.reduce(handlers, html, fn {tag, handler}, acc ->
      tag = to_string(tag)

      acc
      |> replace_paired_tag(tag, fn attrs, inner ->
        call_custom_handler(handler, tag, attrs, inner)
      end)
      |> replace_single_tag(tag, fn attrs ->
        call_custom_handler(handler, tag, attrs, "")
      end)
    end)
  end

  defp call_custom_handler(handler, tag, attrs, inner) when is_function(handler, 1) do
    handler.(%{tag: tag, attrs: attrs, inner_html: inner, text: html_text(inner, %__MODULE__{})})
  end

  defp call_custom_handler(handler, tag, attrs, inner) when is_function(handler, 2) do
    handler.(tag, %{attrs: attrs, inner_html: inner, text: html_text(inner, %__MODULE__{})})
  end

  defp replace_media(html, splitter) do
    html
    |> maybe_replace_media(:preserve_images, "img", "image", splitter)
    |> maybe_replace_media(:preserve_videos, "video", "video", splitter)
    |> maybe_replace_media(:preserve_audio, "audio", "audio", splitter)
  end

  defp maybe_replace_media(html, flag, tag, label, splitter) do
    if Map.fetch!(splitter, flag) do
      html
      |> replace_paired_tag(tag, fn attrs, _inner -> markdown_media(label, attrs["src"] || "") end)
      |> replace_single_tag(tag, fn attrs -> markdown_media(label, attrs["src"] || "") end)
    else
      html
    end
  end

  defp markdown_media(label, src), do: "![#{label}:#{src}](#{src})"

  defp replace_links(html, %{preserve_links: false}), do: html

  defp replace_links(html, %{preserve_links: true}) do
    replace_paired_tag(html, "a", fn attrs, inner ->
      text = html_text(inner, %__MODULE__{})
      "[#{text}](#{attrs["href"] || ""})"
    end)
  end

  defp filter_tags(html, splitter) do
    html
    |> filter_allowlist(splitter)
    |> filter_denylist(splitter)
  end

  defp filter_allowlist(html, %{allowlist_tags: nil}), do: html

  defp filter_allowlist(html, splitter) do
    allowed =
      (List.wrap(splitter.allowlist_tags) ++ Enum.map(splitter.headers, &elem(&1, 0)))
      |> Enum.map(&String.downcase(to_string(&1)))
      |> MapSet.new()

    html
    |> tag_names()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> Enum.reduce(html, &remove_tag(&2, &1))
  end

  defp filter_denylist(html, %{denylist_tags: nil}), do: html

  defp filter_denylist(html, splitter) do
    splitter.denylist_tags
    |> List.wrap()
    |> Enum.map(&String.downcase(to_string(&1)))
    |> Enum.reject(fn tag ->
      Enum.any?(splitter.headers, &(String.downcase(elem(&1, 0)) == tag))
    end)
    |> Enum.reduce(html, &remove_tag(&2, &1))
  end

  defp remove_tag(html, tag) do
    html
    |> String.replace(Regex.compile!("<#{tag}\\b[^>]*>.*?</#{tag}>", "is"), " ")
    |> String.replace(Regex.compile!("</?#{tag}\\b[^>]*?/?>", "is"), " ")
  end

  defp tag_names(html) do
    ~r/<\/?\s*([a-zA-Z][a-zA-Z0-9:-]*)\b/u
    |> Regex.scan(html)
    |> Enum.map(fn [_all, tag] -> String.downcase(tag) end)
    |> Enum.uniq()
  end

  defp create_docs(_splitter, "", _metadata), do: []

  defp create_docs(splitter, content, metadata) do
    if String.length(content) <= splitter.chunk_size do
      [Document.new!(content, metadata: metadata)]
    else
      opts =
        [
          chunk_size: splitter.chunk_size,
          chunk_overlap: splitter.chunk_overlap,
          keep_separator: splitter.keep_separator
        ]
        |> maybe_put(:separators, splitter.separators)

      opts
      |> RecursiveCharacter.new()
      |> RecursiveCharacter.split_text(content)
      |> Enum.map(&Document.new!(&1, metadata: metadata))
    end
  end

  defp html_text(html, splitter) do
    html
    |> String.replace(~r/<br\s*\/?>/iu, " ")
    |> String.replace(
      ~r/<\/(p|div|li|tr|td|th|ul|ol|table|section|article|blockquote|h[1-6])>/iu,
      " "
    )
    |> String.replace(~r/<[^>]*>/u, " ")
    |> decode_entities()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> normalize_text(splitter)
    |> remove_stopwords(splitter)
  end

  defp normalize_text(text, %{normalize_text: true}) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}_\s]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp normalize_text(text, _splitter), do: text

  defp remove_stopwords(text, %{stopword_removal: true, stopwords: stopwords}) do
    stopwords =
      stopwords || ~w(a an and are as at be by for from in is it of on or that the this to with)

    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.reject(&(String.downcase(&1) in stopwords))
    |> Enum.join(" ")
  end

  defp remove_stopwords(text, _splitter), do: text

  defp replace_paired_tag(html, tag, fun) do
    regex = Regex.compile!("<#{tag}\\b([^>]*)>(.*?)</#{tag}>", "is")

    Regex.replace(regex, html, fn _all, attrs, inner ->
      fun.(parse_attrs(attrs), inner)
    end)
  end

  defp replace_single_tag(html, tag, fun) do
    regex = Regex.compile!("<#{tag}\\b([^>]*)/?>", "is")

    Regex.replace(regex, html, fn _all, attrs ->
      fun.(parse_attrs(attrs))
    end)
  end

  defp parse_attrs(attrs) do
    ~r/([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*["']([^"']*)["']/u
    |> Regex.scan(attrs)
    |> Map.new(fn [_all, key, value] -> {String.downcase(key), decode_entities(value)} end)
  end

  defp decode_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp normalize_alias(opts, from, to) do
    case Keyword.fetch(opts, from) do
      {:ok, value} -> opts |> Keyword.delete(from) |> Keyword.put(to, value)
      :error -> opts
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
