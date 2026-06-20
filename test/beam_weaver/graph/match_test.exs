defmodule BeamWeaver.Graph.MatchTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Graph.Match

  test "empty list condition never matches" do
    refute Match.match?([], %{}, %{})
    refute Match.match?([], %{a: 1}, %{})
    refute Match.match?([], :anything, %{})
    refute Match.match?([], nil, %{})
  end

  test "non-keyword list condition uses membership" do
    assert Match.match?([:a, :b], :a, %{})
    refute Match.match?([:a, :b], :c, %{})
  end

  test "keyword list condition uses subset map match" do
    assert Match.match?([status: :ok], %{status: :ok, extra: 1}, %{})
    refute Match.match?([status: :ok], %{status: :error}, %{})
  end

  test "value match treats empty list as never matching" do
    refute Match.match?(%{key: []}, %{key: %{}}, %{})
    refute Match.match?(%{key: []}, %{key: :anything}, %{})
  end

  test "value match uses membership for non-keyword lists" do
    assert Match.match?(%{key: [:a, :b]}, %{key: :a}, %{})
    refute Match.match?(%{key: [:a, :b]}, %{key: :c}, %{})
  end
end
