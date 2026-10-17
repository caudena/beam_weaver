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

  test "pretty encoder handles atoms and structs the way plain encoding does" do
    value = %{"status" => :ok, "at" => ~U[2026-01-01 00:00:00Z], "list" => [:a, nil]}

    assert JSON.decode!(JSON.encode!(value, pretty: true)) == JSON.decode!(JSON.encode!(value))
  end
end
