defmodule BeamWeaver.OutputParser.XMLTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.OutputParser.XML

  test "parses multibyte text content without corruption" do
    assert {:ok, %{name: "msg", text: "héllo"}} = XML.parse("<msg>héllo</msg>")
  end

  test "parses multibyte text that precedes a nested tag" do
    assert {:ok, %{name: "a", children: [%{name: "b", text: "x"}]} = node} =
             XML.parse("<a>héllo<b>x</b></a>")

    assert node.text == "héllo"
  end

  test "parses an element with multibyte attribute values" do
    assert {:ok, %{name: "a", text: "hi", attributes: %{"title" => "café"}}} =
             XML.parse(~s(<a title="café">hi</a>))
  end
end
