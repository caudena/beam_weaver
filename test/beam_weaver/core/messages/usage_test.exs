defmodule BeamWeaver.Core.Messages.UsageTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Messages.Usage

  describe "subtract/2" do
    test "clamps keys present only on the right operand to zero" do
      assert Usage.subtract(%{input_tokens: 10}, %{input_tokens: 3, cache_read_tokens: 5}) ==
               %{input_tokens: 7, cache_read_tokens: 0}
    end

    test "clamps right-only keys when left is nil" do
      assert Usage.subtract(nil, %{cache_read_tokens: 5}) == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               cache_read_tokens: 0
             }
    end

    test "keeps keys present only on the left operand" do
      assert Usage.subtract(%{input_tokens: 10, reasoning_tokens: 4}, %{input_tokens: 3}) ==
               %{input_tokens: 7, reasoning_tokens: 4}
    end

    test "clamps negative differences to zero" do
      assert Usage.subtract(%{input_tokens: 2}, %{input_tokens: 5}) == %{input_tokens: 0}
    end

    test "recurses into nested maps and clamps nested right-only keys" do
      left = %{input_tokens: 10, details: %{audio_tokens: 4}}
      right = %{input_tokens: 3, details: %{audio_tokens: 1, image_tokens: 2}}

      assert Usage.subtract(left, right) ==
               %{input_tokens: 7, details: %{audio_tokens: 3, image_tokens: 0}}
    end
  end
end
