defmodule BeamWeaver.CrossEncoderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.CrossEncoder

  defmodule WordOverlap do
    @behaviour CrossEncoder

    defstruct []

    @impl true
    def score(%__MODULE__{}, pairs, _opts) do
      {:ok, Enum.map(pairs, &overlap_score/1)}
    end

    defp overlap_score({left, right}) do
      left_words = word_set(left)
      right_words = word_set(right)

      if MapSet.size(left_words) == 0 do
        0.0
      else
        MapSet.intersection(left_words, right_words)
        |> MapSet.size()
        |> Kernel./(MapSet.size(left_words))
      end
    end

    defp word_set(text) do
      text
      |> String.downcase()
      |> String.split(~r/\W+/, trim: true)
      |> MapSet.new()
    end
  end

  test "scores text pairs through an explicit cross encoder behaviour" do
    assert {:ok, [first, second]} =
             CrossEncoder.score(%WordOverlap{}, [
               {"hello world", "world hello"},
               {"beam", "python"}
             ])

    assert_in_delta first, 1.0, 0.0001
    assert_in_delta second, 0.0, 0.0001
  end

  test "returns tagged errors for unsupported models and invalid text pairs" do
    assert {:error, %Error{type: :unsupported_cross_encoder}} =
             CrossEncoder.score(%{}, [{"a", "b"}])

    assert {:error, %Error{type: :invalid_cross_encoder_input}} =
             CrossEncoder.score(%WordOverlap{}, "not-pairs")
  end
end
