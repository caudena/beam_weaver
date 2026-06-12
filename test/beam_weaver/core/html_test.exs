defmodule BeamWeaver.Core.HTMLTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.HTML

  test "find_all_links returns none single and multiple links" do
    assert HTML.find_all_links("<span>Hello world</span>") == []

    for html <- [
          "href='foobar.com'",
          ~s(href="foobar.com"),
          ~s(<div><a class="blah" href="foobar.com">hullo</a></div>)
        ] do
      assert HTML.find_all_links(html) == ["foobar.com"]
    end

    html =
      ~s(<div><a class="blah" href="https://foobar.com">hullo</a></div>) <>
        ~s(<div><a class="bleh" href="/baz/cool">buhbye</a></div>)

    assert HTML.find_all_links(html) == ["/baz/cool", "https://foobar.com"]
  end

  test "find_all_links ignores configured suffixes prefixes and fragments" do
    for suffix <- HTML.ignored_suffixes() do
      assert HTML.find_all_links(~s(href="foobar#{suffix}")) == []
      assert HTML.find_all_links(~s(href="foobar#{suffix}more")) == ["foobar#{suffix}more"]
    end

    for prefix <- HTML.ignored_prefixes() do
      assert HTML.find_all_links(~s(href="#{prefix}foobar")) == []
    end

    for prefix <- HTML.ignored_prefixes() -- ["#"] do
      assert HTML.find_all_links(~s(href="foobar#{prefix}more")) == ["foobar#{prefix}more"]
    end

    assert HTML.find_all_links(~s(href="foobar.com/woah#section_one")) == ["foobar.com/woah"]
  end

  test "extract_sub_links resolves relative protocol-relative and external links" do
    html =
      ~s(<a href="https://foobar.com">one</a>) <>
        ~s(<a href="http://baz.net">two</a>) <>
        ~s(<a href="//foobar.com/hello">three</a>) <>
        ~s(<a href="/how/are/you/doing">four</a>)

    assert HTML.extract_sub_links(html, "https://foobar.com") == [
             "https://foobar.com",
             "https://foobar.com/hello",
             "https://foobar.com/how/are/you/doing"
           ]

    assert HTML.extract_sub_links(html, "https://foobar.com/hello") == [
             "https://foobar.com/hello"
           ]

    assert HTML.extract_sub_links(html, "https://foobar.com/hello", prevent_outside: false) == [
             "http://baz.net",
             "https://foobar.com",
             "https://foobar.com/hello",
             "https://foobar.com/how/are/you/doing"
           ]
  end

  test "extract_sub_links supports base URLs excludes and full outside prevention" do
    html =
      ~s(<a href="https://foobar.com">one</a>) <>
        ~s(<a href="http://baz.net">two</a>) <>
        ~s(<a href="//foobar.com/hello">three</a>) <>
        ~s(<a href="/how/are/you/doing">four</a>) <>
        ~s(<a href="alexis.html"</a>)

    assert HTML.extract_sub_links(html, "https://foobar.com/hello/bill.html", base_url: "https://foobar.com") == [
             "https://foobar.com",
             "https://foobar.com/hello",
             "https://foobar.com/hello/alexis.html",
             "https://foobar.com/how/are/you/doing"
           ]

    assert HTML.extract_sub_links(html, "https://foobar.com/hello/bill.html",
             base_url: "https://foobar.com",
             prevent_outside: false,
             exclude_prefixes: ["https://foobar.com/how", "http://baz.org"]
           ) == [
             "http://baz.net",
             "https://foobar.com",
             "https://foobar.com/hello",
             "https://foobar.com/hello/alexis.html"
           ]

    outside_html =
      ~s(<a href="https://foobar.comic.com">BAD</a>) <>
        ~s(<a href="https://foobar.comic:9999">BAD</a>) <>
        ~s(<a href="https://foobar.com:9999">BAD</a>) <>
        ~s(<a href="http://foobar.com:9999/">BAD</a>) <>
        ~s(<a href="https://foobar.com/OK">OK</a>) <>
        ~s(<a href="http://foobar.com/BAD">BAD</a>)

    assert HTML.extract_sub_links(outside_html, "https://foobar.com/hello/bill.html",
             base_url: "https://foobar.com",
             prevent_outside: true
           ) == ["https://foobar.com/OK"]
  end

  test "extract_sub_links preserves query strings" do
    html =
      ~s(<a href="https://foobar.com?query=123">one</a>) <>
        ~s(<a href="/hello?query=456">two</a>) <>
        ~s(<a href="//foobar.com/how/are/you?query=789">three</a>) <>
        ~s(<a href="doing?query=101112"></a>)

    assert HTML.extract_sub_links(html, "https://foobar.com/hello/bill.html", base_url: "https://foobar.com") == [
             "https://foobar.com/hello/doing?query=101112",
             "https://foobar.com/hello?query=456",
             "https://foobar.com/how/are/you?query=789",
             "https://foobar.com?query=123"
           ]
  end
end
