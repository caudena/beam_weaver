defmodule BeamWeaver.ResultTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Result

  test "traverse returns ordered successes" do
    assert {:ok, [2, 4, 6]} = Result.traverse([1, 2, 3], &{:ok, &1 * 2})
  end

  test "traverse stops at the first error" do
    assert {:error, :bad} =
             Result.traverse([1, 2, 3], fn
               1 -> {:ok, :one}
               2 -> {:error, :bad}
               value -> flunk("unexpected traversal after error: #{inspect(value)}")
             end)
  end

  test "flat_traverse flattens mapped lists in order" do
    assert {:ok, [1, 10, 2, 20]} =
             Result.flat_traverse([1, 2], fn value -> {:ok, [value, value * 10]} end)
  end

  test "collect handles empty input" do
    assert {:ok, []} = Result.collect([])
  end
end
