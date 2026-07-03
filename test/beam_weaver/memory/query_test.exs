defmodule BeamWeaver.Memory.QueryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Memory.Query

  defmodule Profile do
    defstruct [:name]
  end

  describe "matches_query?/2" do
    test "searches value and metadata content without wrapper field names" do
      item = %{value: %{"title" => "alpha"}, metadata: %{"source" => "manual"}}

      assert Query.matches_query?(item, "alpha")
      assert Query.matches_query?(item, "manual")
      assert Query.matches_query?(item, "title")
      assert Query.matches_query?(item, "source")

      refute Query.matches_query?(item, "value")
      refute Query.matches_query?(item, "metadata")
    end

    test "does not match DateTime struct inspection text" do
      timestamp = DateTime.from_naive!(~N[2024-01-02 03:04:05], "Etc/UTC")
      item = %{value: %{"seen_at" => timestamp}, metadata: %{}}

      assert Query.matches_query?(item, "2024-01-02")

      refute Query.matches_query?(item, "DateTime")
      refute Query.matches_query?(item, "Calendar.ISO")
    end

    test "does not match arbitrary struct module names" do
      item = %{value: %{"profile" => %Profile{name: "Ada"}}, metadata: %{}}

      assert Query.matches_query?(item, "Ada")

      refute Query.matches_query?(item, "BeamWeaver.Memory.QueryTest.Profile")
      refute Query.matches_query?(item, "struct")
    end
  end

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
