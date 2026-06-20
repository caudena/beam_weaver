defmodule BeamWeaver.VectorStore.FilterTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.VectorStore.Filter

  test "to_sql renders $or as nested OR with sequential placeholders" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"$or" => [%{"a" => 1}, %{"b" => 2}]})
    assert sql =~ "OR"
    assert length(params) == 2
    assert sql =~ "$1"
    assert sql =~ "$2"
  end

  test "to_sql renders $and as nested AND" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"$and" => [%{"a" => 1}, %{"b" => 2}]})
    assert sql =~ "AND"
    assert length(params) == 2
  end

  test "to_sql renders $not as a negation" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"$not" => %{"a" => 1}})
    assert sql =~ "NOT"
    assert length(params) == 1
  end

  test "atom logical operators are also supported" do
    assert {:ok, {sql, _params}} = Filter.to_sql(%{or: [%{"a" => 1}, %{"b" => 2}]})
    assert sql =~ "OR"
  end
end
