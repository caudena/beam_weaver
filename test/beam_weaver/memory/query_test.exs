defmodule BeamWeaver.Memory.QueryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Memory.Query

  describe "matches_filter?/2 with map-valued fields" do
    test "matches an exact literal map value" do
      item = %{value: %{"address" => %{"city" => "NYC"}}, metadata: %{}}

      assert Query.matches_filter?(item, %{"address" => %{"city" => "NYC"}})
    end

    test "does not match when the literal map value differs" do
      item = %{value: %{"address" => %{"city" => "NYC"}}, metadata: %{}}

      refute Query.matches_filter?(item, %{"address" => %{"city" => "LA"}})
    end

    test "still interprets $-operator maps as operators" do
      item = %{value: %{"age" => 30}, metadata: %{}}

      assert Query.matches_filter?(item, %{"age" => %{"$gte" => 18}})
      refute Query.matches_filter?(item, %{"age" => %{"$gte" => 40}})
    end
  end
end
