defmodule BeamWeaver.Sandbox.OutputBufferTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Sandbox.OutputBuffer

  test "output within the limit comes back whole" do
    assert collect(["hello ", "world"], 11) == {"hello world", false}
    assert collect([], 11) == {"", false}
    assert collect(["anything at all"], :unlimited) == {"anything at all", false}
  end

  test "longer output keeps its first and last halves, with a line that says how many bytes were cut" do
    output = String.duplicate("a", 600) <> String.duplicate("b", 600)

    assert collect([output], 100) ==
             {String.duplicate("a", 50) <> "\n... [1100 bytes cut] ...\n" <> String.duplicate("b", 50), true}
  end

  test "the result is the same however the output arrives" do
    output = for i <- 1..2_000, into: "", do: "line #{i}\n"
    chunks = for <<byte::binary-size(1) <- output>>, do: byte

    assert collect(chunks, 1_000) == collect([output], 1_000)
    assert {kept, true} = collect(chunks, 1_000)
    assert String.starts_with?(kept, binary_part(output, 0, 500))
    assert String.ends_with?(kept, binary_part(output, byte_size(output) - 500, 500))
  end

  test "neither half ends in part of a UTF-8 character" do
    output = String.duplicate("é", 100)

    assert {kept, true} = collect([output], 51)

    assert [head, cut, tail] =
             Regex.run(~r/\A(.*)\n\.\.\. \[(\d+) bytes cut\] \.\.\.\n(.*)\z/su, kept, capture: :all_but_first)

    assert String.valid?(head) and String.valid?(tail)
    assert {byte_size(head), byte_size(tail)} == {24, 26}
    assert String.to_integer(cut) == 200 - 24 - 26
  end

  defp collect(chunks, max_bytes), do: Enum.into(chunks, %OutputBuffer{max_bytes: max_bytes})
end
