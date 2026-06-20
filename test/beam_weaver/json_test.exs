defmodule BeamWeaver.JSONTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.JSON

  test "pretty encoder escapes control characters into valid, round-trippable JSON" do
    value = %{"k" => "a\tb\bc\fd\aef"}

    pretty = JSON.encode!(value, pretty: true)

    assert {:ok, decoded} = JSON.decode(pretty)
    assert decoded == value
  end

  test "pretty encoder still handles ordinary strings, quotes, and backslashes" do
    value = %{"path" => "C:\\tmp\\file", "quote" => ~s(say "hi")}

    pretty = JSON.encode!(value, pretty: true)

    assert {:ok, ^value} = JSON.decode(pretty)
  end
end
