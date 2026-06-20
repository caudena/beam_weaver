defmodule BeamWeaver.TextSplitterTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.TextSplitter
  alias BeamWeaver.Tokenizer.Approximate

  test "character splitter matches upstream word-boundary overlap behavior" do
    splitter = TextSplitter.character(separator: " ", chunk_size: 7, chunk_overlap: 3)

    assert TextSplitter.split_text(splitter, "foo bar baz 123") == [
             "foo bar",
             "bar baz",
             "baz 123"
           ]
  end

  test "character splitter drops empty chunks and handles edge inputs" do
    # Translates upstream empty-doc, separator-empty-doc, empty-input, and whitespace-only cases.
    assert TextSplitter.split_text(
             TextSplitter.character(separator: " ", chunk_size: 2, chunk_overlap: 0),
             "foo  bar"
           ) == ["foo", "bar"]

    assert TextSplitter.split_text(
             TextSplitter.character(separator: " ", chunk_size: 2, chunk_overlap: 0),
             "f b"
           ) == ["f", "b"]

    assert TextSplitter.split_text(
             TextSplitter.character(separator: " ", chunk_size: 5, chunk_overlap: 0),
             ""
           ) == []

    assert TextSplitter.split_text(
             TextSplitter.character(separator: " ", chunk_size: 5, chunk_overlap: 0),
             " "
           ) == []
  end

  test "character splitter uses whole split-piece overlap semantics" do
    assert TextSplitter.split_text(
             TextSplitter.character(separator: " ", chunk_size: 3, chunk_overlap: 1),
             "foo bar baz a a"
           ) == ["foo", "bar", "baz", "a a"]

    assert TextSplitter.split_text(
             TextSplitter.character(separator: " ", chunk_size: 3, chunk_overlap: 1),
             "a a foo bar baz"
           ) == ["a a", "foo", "bar", "baz"]

    assert TextSplitter.split_text(
             TextSplitter.character(separator: " ", chunk_size: 1, chunk_overlap: 1),
             "foo bar baz 123"
           ) == ["foo", "bar", "baz", "123"]

    assert TextSplitter.split_text(
             TextSplitter.character(separator: " ", chunk_size: 10, chunk_overlap: 0),
             "singleword"
           ) == ["singleword"]
  end

  test "character splitter supports regex separators and start/end separator retention" do
    # Translates upstream keep_separator regex start/end/discard tests.
    text = "foo.bar.baz.123"

    assert TextSplitter.split_text(
             TextSplitter.character(
               separator: Regex.escape("."),
               separator_regex?: true,
               chunk_size: 1,
               chunk_overlap: 0,
               keep_separator: true
             ),
             text
           ) == ["foo", ".bar", ".baz", ".123"]

    assert TextSplitter.split_text(
             TextSplitter.character(
               separator: ".",
               chunk_size: 1,
               chunk_overlap: 0,
               keep_separator: :end
             ),
             text
           ) == ["foo.", "bar.", "baz.", "123"]

    assert TextSplitter.split_text(
             TextSplitter.character(separator: ".", chunk_size: 1, chunk_overlap: 0),
             text
           ) == ["foo", "bar", "baz", "123"]
  end

  test "character splitter rejects string separator retention modes" do
    splitter =
      TextSplitter.character(
        separator: ".",
        chunk_size: 1,
        chunk_overlap: 0,
        keep_separator: "end"
      )

    assert_raise ArgumentError,
                 ~s(keep_separator must be false, true, :start, or :end, got "end"; use :end),
                 fn -> TextSplitter.split_text(splitter, "foo.bar") end
  end

  test "chunk overlap equal to chunk size is accepted for already-small text" do
    # Translates upstream test_character_text_splitter_handle_chunksize_equal_to_chunkoverlap.
    splitter = TextSplitter.character(separator: " ", chunk_size: 5, chunk_overlap: 5)

    assert TextSplitter.split_text(splitter, "hello") == ["hello"]
  end

  test "recursive character splitting respects chunk size, overlap, separators, and start indexes" do
    splitter =
      TextSplitter.recursive_character(
        chunk_size: 12,
        chunk_overlap: 3,
        keep_separator: true,
        add_start_index: true
      )

    {:ok, stream} =
      TextSplitter.split_documents(splitter, [
        Document.new!("alpha beta gamma delta", metadata: %{source: "inline"})
      ])

    chunks = Enum.to_list(stream)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(String.length(&1.content) <= 15))
    assert Enum.all?(chunks, &(&1.metadata.source == "inline"))
    assert Enum.all?(chunks, &is_integer(&1.metadata.start_index))
  end

  test "document-like maps and binaries are accepted without global conversion state" do
    splitter = TextSplitter.character(chunk_size: 6, chunk_overlap: 1)

    {:ok, stream} =
      TextSplitter.split_documents(splitter, [
        "plain text",
        %{content: "mapped text", metadata: %{source: "map"}, id: "mapped"}
      ])

    chunks = Enum.to_list(stream)

    assert Enum.any?(chunks, &(&1.content =~ "plain"))
    assert Enum.any?(chunks, &(&1.id == "mapped" and &1.metadata.source == "map"))
  end

  test "create_documents accepts per-input metadata and does not share metadata maps" do
    # Translates upstream create_documents/create_documents_with_metadata/metadata_not_shallow.
    splitter = TextSplitter.character(separator: " ", chunk_size: 3, chunk_overlap: 0)

    assert {:ok, stream} =
             TextSplitter.create_documents(splitter, ["foo bar", "baz"], metadata: [%{source: "1"}, %{source: "2"}])

    docs = Enum.to_list(stream)

    assert Enum.map(docs, &{&1.content, &1.metadata}) == [
             {"foo", %{source: "1"}},
             {"bar", %{source: "1"}},
             {"baz", %{source: "2"}}
           ]

    changed = %{hd(docs) | metadata: Map.put(hd(docs).metadata, :new, true)}

    assert changed.metadata == %{source: "1", new: true}
    assert Enum.at(docs, 1).metadata == %{source: "1"}
  end

  test "create_documents with start index points back into the source text" do
    # Translates upstream test_create_documents_with_start_index.
    splitter =
      TextSplitter.character(
        separator: " ",
        chunk_size: 7,
        chunk_overlap: 3,
        add_start_index: true
      )

    text = "foo bar baz 123"
    assert {:ok, stream} = TextSplitter.create_documents(splitter, [text])

    assert [
             %Document{content: "foo bar", metadata: %{start_index: 0}},
             %Document{content: "bar baz", metadata: %{start_index: 4}},
             %Document{content: "baz 123", metadata: %{start_index: 8}}
           ] = Enum.to_list(stream)
  end

  test "markdown and html header splitters propagate nested header metadata" do
    {:ok, markdown_stream} =
      TextSplitter.split_documents(TextSplitter.markdown_headers(), [
        "# Guide\nintro\n## Install\nsteps"
      ])

    assert [
             %Document{content: "intro", metadata: %{"Header 1" => "Guide"}},
             %Document{
               content: "steps",
               metadata: %{"Header 1" => "Guide", "Header 2" => "Install"}
             }
           ] = Enum.to_list(markdown_stream)

    {:ok, html_stream} =
      TextSplitter.split_documents(TextSplitter.html_headers(), [
        "<h1>Guide</h1><p>intro</p><h2>Install</h2><p>steps</p>"
      ])

    assert [
             %Document{content: "intro", metadata: %{"Header 1" => "Guide"}},
             %Document{
               content: "steps",
               metadata: %{"Header 1" => "Guide", "Header 2" => "Install"}
             }
           ] = Enum.to_list(html_stream)
  end

  test "markdown header splitter handles indented headers and deeper metadata scopes" do
    # Adapts upstream MarkdownHeaderTextSplitter cases 1-3 to BeamWeaver documents.
    markdown = """
    # Foo

        ## Bar

    Hi this is Jim

    ### Boo

    Hi this is Lance

    #### Bim

    Hi this is John

    ## Baz

    Hi this is Molly
    """

    {:ok, stream} = TextSplitter.split_documents(TextSplitter.markdown_headers(), [markdown])
    docs = Enum.to_list(stream)

    assert Enum.any?(docs, fn doc ->
             doc.content == "Hi this is Jim" and
               doc.metadata == %{"Header 1" => "Foo", "Header 2" => "Bar"}
           end)

    assert Enum.any?(docs, fn doc ->
             doc.content == "Hi this is Lance" and
               doc.metadata == %{
                 "Header 1" => "Foo",
                 "Header 2" => "Bar",
                 "Header 3" => "Boo"
               }
           end)

    assert Enum.any?(docs, fn doc ->
             doc.content == "Hi this is Molly" and
               doc.metadata == %{"Header 1" => "Foo", "Header 2" => "Baz"}
           end)
  end

  test "markdown header splitter ignores fenced-code headings and can retain header lines" do
    markdown = """
    # Guide

    ```md
    # Not a header
    ```

    ## Install
    steps
    """

    {:ok, stream} = TextSplitter.split_documents(TextSplitter.markdown_headers(), [markdown])
    docs = Enum.to_list(stream)

    assert Enum.any?(docs, fn doc ->
             String.contains?(doc.content, "# Not a header") and
               doc.metadata == %{"Header 1" => "Guide"}
           end)

    assert Enum.any?(docs, fn doc ->
             doc.content == "steps" and
               doc.metadata == %{"Header 1" => "Guide", "Header 2" => "Install"}
           end)

    {:ok, retained_stream} =
      TextSplitter.split_documents(TextSplitter.markdown_headers(strip_headers?: false), [
        "# Guide\nintro"
      ])

    assert [%Document{content: "# Guide\nintro"}] = Enum.to_list(retained_stream)
  end

  test "markdown syntax splitter preserves code blocks, horizontal rule splits, and line mode" do
    markdown =
      "# My Header 1\n" <>
        "Content for header 1\n" <>
        "## Header 2\n" <>
        "Content for header 2\n" <>
        "```python\n" <>
        "def func_definition():\n" <>
        "   print('Keep the whitespace consistent')\n" <>
        "```\n" <>
        "# Header 1 again\n" <>
        "We should also split on the horizontal line\n" <>
        "----\n" <>
        "This will be a new doc but with the same header metadata\n\n" <>
        "And it includes a new paragraph"

    {:ok, stream} = TextSplitter.split_documents(TextSplitter.markdown_syntax(), [markdown])
    docs = Enum.to_list(stream)

    assert %Document{
             content: "Content for header 1\n",
             metadata: %{"Header 1" => "My Header 1"}
           } in docs

    assert %Document{
             content: "Content for header 2\n",
             metadata: %{"Header 1" => "My Header 1", "Header 2" => "Header 2"}
           } in docs

    assert Enum.any?(docs, fn doc ->
             doc.content ==
               "```python\ndef func_definition():\n   print('Keep the whitespace consistent')\n```\n" and
               doc.metadata == %{
                 "Code" => "python",
                 "Header 1" => "My Header 1",
                 "Header 2" => "Header 2"
               }
           end)

    assert Enum.any?(docs, fn doc ->
             doc.content == "We should also split on the horizontal line\n" and
               doc.metadata == %{"Header 1" => "Header 1 again"}
           end)

    assert Enum.any?(docs, fn doc ->
             doc.content ==
               "This will be a new doc but with the same header metadata\n\nAnd it includes a new paragraph" and
               doc.metadata == %{"Header 1" => "Header 1 again"}
           end)

    {:ok, line_stream} =
      TextSplitter.split_documents(TextSplitter.markdown_syntax(return_each_line: true), [
        markdown
      ])

    assert Enum.any?(line_stream, fn doc ->
             doc.content == "def func_definition():" and doc.metadata["Code"] == "python"
           end)
  end

  test "markdown syntax splitter supports custom header maps without Python class identity" do
    markdown = "# Mi titulo\nintro\n## Kept as text\nbody"

    {:ok, stream} =
      TextSplitter.split_documents(
        TextSplitter.markdown_syntax(headers: [{"#", "Encabezamiento 1"}]),
        [markdown]
      )

    assert [
             %Document{
               content: "intro\n## Kept as text\nbody",
               metadata: %{"Encabezamiento 1" => "Mi titulo"}
             }
           ] = Enum.to_list(stream)
  end

  test "html headers reset deeper metadata, infer font-size headers, and strip unsafe blocks" do
    html = """
    <h1>Guide</h1><p>intro</p>
    <h2>Install</h2><p>steps<script>alert("x")</script></p>
    <h1>Reference</h1><p>api</p>
    <div style="font-size: 30px">Large</div><p>large body</p>
    <div style="font-size: 20px">Small</div><p>small body</p>
    """

    {:ok, stream} = TextSplitter.split_documents(TextSplitter.html_headers(), [html])
    docs = Enum.to_list(stream)

    assert Enum.any?(docs, fn doc ->
             doc.content == "steps" and
               doc.metadata == %{"Header 1" => "Guide", "Header 2" => "Install"}
           end)

    assert Enum.any?(docs, fn doc ->
             doc.content == "api" and doc.metadata == %{"Header 1" => "Reference"}
           end)

    refute Enum.any?(docs, &String.contains?(&1.content, "alert"))

    assert Enum.any?(docs, fn doc ->
             doc.content == "large body" and doc.metadata["Header 1"] == "Large"
           end)

    assert Enum.any?(docs, fn doc ->
             doc.content == "small body" and doc.metadata["Header 2"] == "Small"
           end)
  end

  test "html splitter tolerates non-heading header tags (html_level fallback)" do
    splitter = TextSplitter.html_semantic(headers: [{"div", "Section"}])

    # Before the fix, html_level("div") crashed with FunctionClauseError.
    assert {:ok, stream} =
             TextSplitter.split_documents(splitter, ["<div>Heading</div>Some body text"])

    docs = Enum.to_list(stream)
    assert Enum.any?(docs, &(&1.content =~ "body text"))
  end

  test "semantic html splitter preserves links, media, custom handlers, filters, metadata, and chunks" do
    iframe = fn %{attrs: attrs} -> "[iframe:#{attrs["src"]}](#{attrs["src"]})" end

    html = """
    <h1>Section 1</h1>
    <p>This is a link to <a href="http://example.com">example.com</a></p>
    <p>This is an iframe:</p>
    <iframe src="http://example.com/frame"></iframe>
    <p>This is an image:</p>
    <img src="http://example.com/image.png" />
    <span>remove me</span>
    """

    splitter =
      TextSplitter.html_semantic(
        headers: [{"h1", "Header 1"}],
        preserve_links: true,
        preserve_images: true,
        custom_handlers: %{"iframe" => iframe},
        denylist_tags: ["span"],
        external_metadata: %{source: "example.com"},
        chunk_size: 1_000
      )

    {:ok, stream} = TextSplitter.split_documents(splitter, [html])

    assert [
             %Document{
               content:
                 "This is a link to [example.com](http://example.com) This is an iframe: [iframe:http://example.com/frame](http://example.com/frame) This is an image: ![image:http://example.com/image.png](http://example.com/image.png)",
               metadata: %{"Header 1" => "Section 1", source: "example.com"}
             }
           ] = Enum.to_list(stream)

    {:ok, chunks} =
      TextSplitter.split_documents(
        TextSplitter.html_semantic(
          headers: [{"h1", "Header 1"}],
          chunk_size: 20,
          chunk_overlap: 5,
          separators: [" "],
          preserve_parent_metadata: true
        ),
        [
          Document.new!("<h1>Section 1</h1><p>This is some long text that should split</p>",
            metadata: %{source: "parent"}
          )
        ]
      )

    chunk_docs = Enum.to_list(chunks)
    assert length(chunk_docs) > 1
    assert Enum.all?(chunk_docs, &(&1.metadata["Header 1"] == "Section 1"))
    assert Enum.all?(chunk_docs, &(&1.metadata.source == "parent"))
  end

  test "token splitter uses an explicit tokenizer adapter" do
    splitter =
      TextSplitter.token(
        chunk_size: 3,
        chunk_overlap: 1,
        tokenizer: %Approximate{mode: :words}
      )

    {:ok, stream} = TextSplitter.split_documents(splitter, ["one two three four five"])

    assert Enum.map(stream, & &1.content) == ["one two three", "three four five"]
  end

  test "token factory helpers keep tokenizer dependencies explicit" do
    splitter =
      Approximate
      |> struct(mode: :words)
      |> TextSplitter.from_tokenizer(chunk_size: 2, chunk_overlap: 1)

    assert TextSplitter.split_text(splitter, "one two three") == ["one two", "two three"]

    openai_splitter =
      Approximate
      |> struct(mode: :words)
      |> TextSplitter.from_tokenizer(chunk_size: 4, chunk_overlap: 1)

    chunks = TextSplitter.split_text(openai_splitter, "hello world from beam weaver")
    assert length(chunks) >= 2
    assert Enum.all?(chunks, &is_binary/1)
  end

  test "transform_documents is the BeamWeaver document-transformer entry point" do
    splitter = TextSplitter.character(separator: " ", chunk_size: 5, chunk_overlap: 0)

    assert {:ok, stream} =
             TextSplitter.transform_documents(splitter, [
               Document.new!("alpha beta", metadata: %{source: "transform"})
             ])

    assert Enum.map(stream, &{&1.content, &1.metadata}) == [
             {"alpha", %{source: "transform"}},
             {"beta", %{source: "transform"}}
           ]
  end

  test "stream_text lazily splits an enumerable of input texts" do
    splitter = TextSplitter.character(separator: " ", chunk_size: 5, chunk_overlap: 0)

    {:ok, stream} =
      TextSplitter.stream_text(splitter, Stream.map(["alpha beta", "gamma"], & &1))

    assert Enum.to_list(stream) == ["alpha", "beta", "gamma"]
  end

  test "recursive JSON splitter keeps nested JSON fragments bounded" do
    splitter = TextSplitter.recursive_json(chunk_size: 20, chunk_overlap: 0)
    json = BeamWeaver.JSON.encode!(%{alpha: %{beta: [1, 2, 3]}, gamma: "delta"})

    chunks = TextSplitter.split_text(splitter, json)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(String.length(&1) <= 20))
    assert Enum.join(chunks, " ") =~ "alpha"
    assert Enum.join(chunks, " ") =~ "gamma"
  end

  test "recursive JSON splitter preserves map chunks, empty maps, and repeated calls" do
    splitter = TextSplitter.recursive_json(max_chunk_size: 80)

    first = TextSplitter.split_json(splitter, %{"a" => 1, "b" => 2})
    second = TextSplitter.split_json(splitter, %{"c" => 3, "d" => 4})

    assert first == [%{"a" => 1, "b" => 2}]
    assert second == [%{"c" => 3, "d" => 4}]
    assert first == [%{"a" => 1, "b" => 2}]

    data = %{
      "config" => %{},
      "metadata" => %{"author" => "test", "tags" => %{}},
      "content" => "some text"
    }

    merged =
      splitter
      |> TextSplitter.split_json(data)
      |> Enum.reduce(
        %{},
        &Map.merge(&2, &1, fn _key, left, right ->
          if is_map(left) and is_map(right), do: Map.merge(left, right), else: right
        end)
      )

    assert merged["config"] == %{}
    assert merged["metadata"] == %{"author" => "test", "tags" => %{}}
    assert merged["content"] == "some text"
    assert TextSplitter.split_json(splitter, %{}) == []
  end

  test "recursive JSON splitter supports list conversion and bounded document output" do
    splitter = TextSplitter.recursive_json(max_chunk_size: 120)

    data = %{
      "key0" => String.duplicate("x", 50),
      "empty" => %{},
      "key1" => String.duplicate("y", 50),
      "nested" => Map.new(1..20, &{"k#{&1}", "v#{&1}"})
    }

    chunks = TextSplitter.split_json(splitter, data)

    assert Enum.all?(chunks, &(BeamWeaver.JSON.encode!(&1) |> byte_size() < 126))
    assert Enum.any?(chunks, &(&1["empty"] == %{}))

    list_chunks =
      TextSplitter.split_json(splitter, %{"testPreprocessing" => [data]}, convert_lists: true)

    assert length(list_chunks) >= length(chunks)

    docs = TextSplitter.create_json_documents(splitter, [data])
    assert Enum.all?(docs, &match?(%Document{}, &1))
    assert Enum.all?(docs, &(byte_size(&1.content) < 126))
  end

  test "recursive JSON splitter honors minimum chunk size and document metadata" do
    splitter = TextSplitter.recursive_json(max_chunk_size: 45, min_chunk_size: 20)

    chunks =
      TextSplitter.split_json(splitter, %{
        "a" => "x",
        "b" => "y",
        "c" => String.duplicate("z", 36)
      })

    assert %{"a" => "x", "b" => "y"} in chunks

    docs =
      TextSplitter.create_json_documents(
        splitter,
        [%{"a" => "x"}, %{"b" => "y"}],
        metadata: [%{source: "first"}, %{source: "second"}]
      )

    assert Enum.any?(docs, &(&1.metadata == %{source: "first"}))
    assert Enum.any?(docs, &(&1.metadata == %{source: "second"}))
  end

  test "latex and code-aware splitters prefer structural separators" do
    # Translates language-aware splitter separator behavior where it maps to
    # BeamWeaver's explicit splitter structs.
    latex = "\\section{Intro}\nHello world\n\\subsection{Setup}\nSteps"

    assert TextSplitter.split_text(
             TextSplitter.latex(chunk_size: 30, chunk_overlap: 0, keep_separator: true),
             latex
           ) == ["\\section{Intro}\nHello world", "\\subsection{Setup}\nSteps"]

    python = "class Foo:\n    pass\n\ndef bar():\n    return 1"

    assert TextSplitter.split_text(
             TextSplitter.python(chunk_size: 25, chunk_overlap: 0, keep_separator: true),
             python
           ) == ["class Foo:\n    pass", "def bar():\n    return 1"]

    jsx = "const App = () => {\n  return <div>Hello</div>\n}\nexport default App"

    jsx_chunks =
      TextSplitter.split_text(
        TextSplitter.jsx(chunk_size: 35, chunk_overlap: 0, keep_separator: true),
        jsx
      )

    assert length(jsx_chunks) > 1
    assert Enum.any?(jsx_chunks, &String.contains?(&1, "return"))
    assert Enum.any?(jsx_chunks, &String.contains?(&1, "export default"))
  end

  test "language separator factory builds recursive splitters without Python class aliases" do
    assert ["\nclass ", "\ndef " | _] = TextSplitter.get_separators_for_language(:python)
    assert "\ndefmodule " in TextSplitter.get_separators_for_language("exs")
    assert "\ndef " in TextSplitter.get_separators_for_language("exs")
    assert ["\nfunc ", "\nvar " | _] = TextSplitter.get_separators_for_language(:golang)
    assert ["\nfn ", "\nconst " | _] = TextSplitter.get_separators_for_language(:rust)
    assert ["\npragma ", "\nusing " | _] = TextSplitter.get_separators_for_language(:solidity)
    assert ["\nfunction ", "\nparam " | _] = TextSplitter.get_separators_for_language(:powershell)
    assert ["\nfunction ", "\nconst " | _] = TextSplitter.get_separators_for_language(:vue)

    splitter =
      TextSplitter.from_language(:python,
        chunk_size: 25,
        chunk_overlap: 0,
        keep_separator: true
      )

    assert TextSplitter.split_text(splitter, "class Foo:\n    pass\n\ndef bar():\n    return 1") ==
             [
               "class Foo:\n    pass",
               "def bar():\n    return 1"
             ]

    assert TextSplitter.from_language(:does_not_exist).__struct__ ==
             BeamWeaver.TextSplitter.RecursiveCharacter
  end

  test "language splitters cover upstream code language families" do
    cases = [
      {:cpp, "class User {};\n\nvoid run() {}\n\nint value = 1;"},
      {:csharp, "interface IUser {}\n\npublic class User {}\n\nprivate int value;"},
      {:go, "package main\n\nfunc main() {\nprintln(\"hi\")\n}\n\ntype User struct{}"},
      {:html, "<html><body><h1>Title</h1><p>Hello</p><div>Body</div></body></html>"},
      {:java, "class A {}\n\npublic void run() {}\n\nprivate int value;"},
      {:kotlin, "class A\n\nfun run() = Unit\n\nval value = 1"},
      {:php, "<?php\nfunction run() {}\n\nclass A {}"},
      {:powershell, "function Run {}\n\nparam($Value)\n\nif ($Value) {}"},
      {:proto, "syntax = \"proto3\";\n\nmessage User {}\n\nservice Users {}"},
      {:r, "function(x) x\n\nsetClass(\"A\")\n\nlibrary(stats)"},
      {:rst, "Title\n=====\n\nSection\n-------\n\nBody"},
      {:ruby, "class A\nend\n\ndef run\nend"},
      {:rust, "fn main() {}\n\nconst VALUE: i32 = 1;\n\nmatch value {}"},
      {:scala, "class A\n\nobject B\n\ndef run = 1"},
      {:solidity, "pragma solidity ^0.8.0;\n\ncontract C {}\n\nfunction run() public {}"},
      {:swift, "func run() {}\n\nstruct User {}\n\nclass A {}"},
      {:typescript, "interface User {}\n\ntype Id = string\n\nconst value = 1"},
      {:vue, "<template><div>Hello</div></template>\n\n<script>const x = 1</script>"},
      {:svelte, "<script>const x = 1</script>\n\n<div>Hello</div>"},
      {:cobol, "IDENTIFICATION DIVISION.\nPROGRAM-ID. TEST.\nPROCEDURE DIVISION.\nDISPLAY 'HI'."},
      {:lua, "local x = 1\n\nfunction run()\nend"},
      {:haskell, "module Main where\n\nmain :: IO ()\nmain = pure ()"},
      {:visualbasic6, "Public Sub Run()\nEnd Sub\n\nPrivate Function Value()\nEnd Function"}
    ]

    for {language, source} <- cases do
      splitter = TextSplitter.from_language(language, chunk_size: 35, chunk_overlap: 0)
      chunks = TextSplitter.split_text(splitter, source)
      assert chunks != []
      assert Enum.all?(chunks, &is_binary/1)
    end
  end

  test "invalid splitter options return tagged errors before enumeration" do
    # Translates upstream invalid size/overlap tests, with BeamWeaver's tagged-error boundary.
    splitter = TextSplitter.character(chunk_size: 4, chunk_overlap: 5)

    assert {:error, %{type: :invalid_text_splitter}} =
             TextSplitter.split_documents(splitter, ["will not enumerate"])
  end

  test "stream input remains lazy" do
    parent = self()
    splitter = TextSplitter.character(chunk_size: 10, chunk_overlap: 0)

    source =
      Stream.map(["lazy document"], fn text ->
        send(parent, :enumerated)
        text
      end)

    assert {:ok, stream} = TextSplitter.split_documents(splitter, source)
    refute_received :enumerated
    assert [%Document{} | _] = Enum.to_list(stream)
    assert_received :enumerated
  end

  test "file and URL splitting use explicit IO boundaries with document metadata" do
    path = Path.join(System.tmp_dir!(), "beam_weaver_splitter_#{System.unique_integer()}.html")
    File.write!(path, "<h1>Guide</h1><p>from file</p>")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, file_stream} = TextSplitter.split_file(TextSplitter.html_headers(), path)

    assert [%Document{content: "from file", metadata: %{source: ^path}}] =
             Enum.to_list(file_stream)

    fetcher = fn "https://example.test/doc" -> {:ok, "<h1>Guide</h1><p>from url</p>"} end

    assert {:ok, url_stream} =
             TextSplitter.split_url(TextSplitter.html_headers(), "https://example.test/doc", fetcher: fetcher)

    assert [%Document{content: "from url", metadata: %{source: "https://example.test/doc"}}] =
             Enum.to_list(url_stream)
  end
end
