defmodule BeamWeaver.VectorStoreScoringTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.VectorStore.Scoring

  test "cosine_similarity returns pairwise matrix scores" do
    assert_matrix_close(
      [[1.0, 0.0], [0.0, 1.0]],
      Scoring.cosine_similarity([[1, 0], [0, 1]], [[1, 0], [0, 1]])
    )

    assert_matrix_close([[1.0]], Scoring.cosine_similarity([[1, 2, 3]], [[1, 2, 3]]))
    assert_matrix_close([[-1.0]], Scoring.cosine_similarity([[1, 2, 3]], [[-1, -2, -3]]))
  end

  test "cosine_similarity handles multiple dimensions and empty matrices" do
    assert_matrix_close(
      [[1.0, 0.0, 0.0], [0.0, 0.0, 0.0]],
      Scoring.cosine_similarity(
        [[1, 0, 0, 0], [0, 1, 0, 0]],
        [[1, 0, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
      )
    )

    assert {:ok, [[]]} = Scoring.cosine_similarity([], [])
    assert {:ok, [[]]} = Scoring.cosine_similarity([], [[1, 2, 3]])
  end

  test "cosine_similarity supports tuples, large values, small values, and single dimensions" do
    assert_matrix_close(
      [[1.0, 0.0]],
      Scoring.cosine_similarity([{1.0e6, 1.0e6}], [[1.0e6, 1.0e6], [1.0e6, -1.0e6]])
    )

    assert_matrix_close(
      [[1.0, 0.0]],
      Scoring.cosine_similarity([[1.0e-10, 1.0e-10]], [
        [1.0e-10, 1.0e-10],
        [1.0e-10, -1.0e-10]
      ])
    )

    assert_matrix_close(
      [[1.0, -1.0, 1.0], [-1.0, 1.0, -1.0]],
      Scoring.cosine_similarity([[5], [-3]], [[2], [-1], [4]])
    )
  end

  test "cosine_similarity reports dimension mismatch and zero-vector errors as tagged errors" do
    assert {:error, error} = Scoring.cosine_similarity([[1, 2]], [[1, 2, 3]])
    assert error.type == :dimension_mismatch
    assert error.message =~ "Number of columns"

    assert {:error, error} = Scoring.cosine_similarity([[0, 0]], [[1, 2]])
    assert error.type == :invalid_vector
    assert error.message =~ "NaN values found"
  end

  defp assert_matrix_close(expected, {:ok, actual}) do
    assert length(actual) == length(expected)

    expected
    |> Enum.zip(actual)
    |> Enum.each(fn {expected_row, actual_row} ->
      assert length(actual_row) == length(expected_row)

      expected_row
      |> Enum.zip(actual_row)
      |> Enum.each(fn {expected_value, actual_value} ->
        assert_in_delta actual_value, expected_value, 1.0e-9
      end)
    end)
  end
end
