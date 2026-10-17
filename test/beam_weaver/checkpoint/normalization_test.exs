defmodule BeamWeaver.Checkpoint.NormalizationTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.Normalization

  test "configurable returns empty map when configurable key is explicitly nil" do
    assert Normalization.configurable(%{configurable: nil}) == %{}
    assert Normalization.configurable(%{"configurable" => nil}) == %{}
    assert Normalization.configurable(configurable: nil) == %{}
  end

  test "configurable stringifies keys from map and keyword configurable values" do
    assert Normalization.configurable(%{configurable: %{thread_id: "t"}}) == %{"thread_id" => "t"}
    assert Normalization.configurable(%{"configurable" => [thread_id: "t"]}) == %{"thread_id" => "t"}
  end

  test "configurable drops an empty or nil checkpoint_id, which means the latest checkpoint" do
    for id <- ["", nil] do
      assert Normalization.configurable(%{"configurable" => %{"thread_id" => "t", "checkpoint_id" => id}}) ==
               %{"thread_id" => "t"}

      assert Normalization.configurable(configurable: [thread_id: "t", checkpoint_id: id]) == %{"thread_id" => "t"}
    end

    assert Normalization.configurable(%{configurable: %{thread_id: "t", checkpoint_id: "c1"}}) ==
             %{"thread_id" => "t", "checkpoint_id" => "c1"}
  end

  test "configurable falls back to the config itself when no configurable key is present" do
    assert Normalization.configurable(%{thread_id: "t"}) == %{"thread_id" => "t"}
  end
end
