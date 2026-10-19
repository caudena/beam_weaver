defmodule BeamWeaver.VectorStore.ScoringTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.VectorStore.Scoring

  test "cosine of vectors with very large or very small components doesn't overflow" do
    assert Scoring.cosine([1.0e300], [1.0]) == 1.0
    assert Scoring.cosine([1.0e300, 0.0], [-2.0e300, 0.0]) == -1.0
    assert_in_delta Scoring.cosine([1.0e300, 1.0e300], [1.0, -1.0]), 0.0, 1.0e-12
    assert_in_delta Scoring.cosine([1.0e308, 1.0e308, 1.0e308], [1.0e308, 1.0e308, 1.0e308]), 1.0, 1.0e-12
    assert_in_delta Scoring.cosine([1.0e-300, 1.0e-300], [1.0, 1.0]), 1.0, 1.0e-12
  end

  test "cosine of ordinary vectors is the textbook formula, within float rounding" do
    pairs = [
      {[1.0, 0.0], [0.0, 1.0]},
      {[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]},
      {[0.1, -0.7, 0.3, 0.2], [-0.4, 0.5, 0.9, -0.1]},
      {[3, 4], [4, 3]},
      {{1.5, -2.5}, {-1.5, 2.5}}
    ]

    for {left, right} <- pairs do
      assert_in_delta Scoring.cosine(left, right), textbook_cosine(left, right), 1.0e-12
    end

    assert Scoring.cosine([0.0, 0.0], [1.0, 1.0]) == 0
    assert Scoring.cosine([1.0, 2.0], [1.0]) == 0
    assert Scoring.cosine([1.0, "a"], [1.0, 2.0]) == 0
  end

  defp textbook_cosine(left, right) do
    [left, right] = Enum.map([left, right], fn v -> if is_tuple(v), do: Tuple.to_list(v), else: v end)
    dot = left |> Enum.zip(right) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
    norm = fn v -> v |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt() end
    dot / (norm.(left) * norm.(right))
  end
end
