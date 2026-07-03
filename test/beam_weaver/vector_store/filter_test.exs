defmodule BeamWeaver.VectorStore.FilterTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.VectorStore.Filter

  test "to_sql renders $or as nested OR with sequential placeholders" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"$or" => [%{"a" => 1}, %{"b" => 2}]})
    assert sql =~ "OR"
    assert length(params) == 4
    assert sql =~ "$1"
    assert sql =~ "$4"
    assert params == [["a"], "1", ["b"], "2"]
  end

  test "to_sql renders $and as nested AND" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"$and" => [%{"a" => 1}, %{"b" => 2}]})
    assert sql =~ "AND"
    assert params == [["a"], "1", ["b"], "2"]
  end

  test "to_sql renders $not as a negation" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"$not" => %{"a" => 1}})
    assert sql =~ "NOT"
    assert params == [["a"], "1"]
  end

  test "atom logical operators are also supported" do
    assert {:ok, {sql, _params}} = Filter.to_sql(%{or: [%{"a" => 1}, %{"b" => 2}]})
    assert sql =~ "OR"
  end

  test "to_sql $like passes the user pattern through unchanged" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"name" => %{"$like" => "foo%"}})
    assert sql =~ "metadata #>> $1::text[] ILIKE $2"
    assert params == [["name"], "foo%"]
  end

  test "to_sql $contain wraps the value in substring wildcards" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"name" => %{"$contain" => "foo"}})
    assert sql =~ "metadata #>> $1::text[] ILIKE $2"
    assert params == [["name"], "%foo%"]
  end

  test "to_sql $like and $contain produce different params for the same value" do
    assert {:ok, {_like_sql, like_params}} = Filter.to_sql(%{"name" => %{"$like" => "foo"}})
    assert {:ok, {_contain_sql, contain_params}} = Filter.to_sql(%{"name" => %{"$contain" => "foo"}})
    assert like_params == [["name"], "foo"]
    assert contain_params == [["name"], "%foo%"]
    refute like_params == contain_params
  end

  test "to_sql parameterizes metadata paths" do
    malicious_path = "x}' AND '1'='1' -- "

    assert {:ok, {sql, params}} = Filter.to_sql(%{malicious_path => "y"}, 3)

    assert sql == "metadata #>> $3::text[] = $4"
    assert params == [[malicious_path], "y"]
    refute sql =~ malicious_path
    refute sql =~ "1'='1"
    refute sql =~ "--"
  end
end
