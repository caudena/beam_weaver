defmodule BeamWeaver.VectorStore.FilterTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.VectorStore.Filter

  test "to_sql renders $or as nested OR with sequential placeholders" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"$or" => [%{"a" => 1}, %{"b" => 2}]}, 1)
    assert sql =~ "OR"
    assert length(params) == 4
    assert sql =~ "$1"
    assert sql =~ "$4"
    assert params == [["a"], "1", ["b"], "2"]
  end

  test "to_sql renders $and as nested AND" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"$and" => [%{"a" => 1}, %{"b" => 2}]}, 1)
    assert sql =~ "AND"
    assert params == [["a"], "1", ["b"], "2"]
  end

  test "to_sql renders $not as a negation" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"$not" => %{"a" => 1}}, 1)
    assert sql =~ "NOT"
    assert params == [["a"], "1"]
  end

  test "atom logical operators are also supported" do
    assert {:ok, {sql, _params}} = Filter.to_sql(%{or: [%{"a" => 1}, %{"b" => 2}]}, 1)
    assert sql =~ "OR"
  end

  test "to_sql $like passes the user pattern through unchanged" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"name" => %{"$like" => "foo%"}}, 1)
    assert sql =~ "metadata #>> $1::text[] ILIKE $2"
    assert params == [["name"], "foo%"]
  end

  test "match? $like follows ILIKE: anchored, case-insensitive, % and _ wildcards, backslash escapes" do
    like? = fn value, pattern -> Filter.match?(%{"n" => value}, %{"n" => %{"$like" => pattern}}) end

    refute like?.("xfooy", "foo")
    assert like?.("FOO", "foo")
    assert like?.("foobar", "foo%")
    assert like?.("xfooy", "%foo%")
    assert like?.("a\nb", "a%b")
    refute like?.("foo\n", "foo")

    assert like?.("fxo", "f_o")
    refute like?.("fo", "f_o")
    refute like?.("fxxo", "f_o")
    assert like?.("é", "_")

    assert like?.("a.c", "a.c")
    refute like?.("abc", "a.c")
    assert like?.("a*c", "a*c")
    refute like?.("aaac", "a*c")
    refute like?.("aab", "a+b")
    refute like?.("a", "[ab]")
    refute like?.("a", "(a|b)")

    assert like?.("a%c", "a\\%c")
    refute like?.("abc", "a\\%c")
    assert like?.("a_c", "a\\_c")
    refute like?.("abc", "a\\_c")
    assert like?.("a\\c", "a\\\\c")
    assert like?.("ac", "a\\c")
    refute like?.("a\\c", "a\\c")
    # Postgres rejects a pattern that ends in the escape character.
    refute like?.("a\\", "a\\")
  end

  test "match? $like matches string values only" do
    like? = fn value, pattern -> Filter.match?(%{"n" => value}, %{"n" => %{"$like" => pattern}}) end

    refute like?.(12, "12")
    refute like?.(true, "true")
    refute like?.(["red"], "%red%")
    refute like?.(%{"red" => 1}, "%red%")
    refute like?.(nil, "%")
  end

  test "match? $contain finds a substring ignoring case, taking %, _ and backslash literally" do
    contain? = fn value, expected -> Filter.match?(%{"n" => value}, %{"n" => %{"$contain" => expected}}) end

    assert contain?.("Hello World", "world")
    assert contain?.("hello", "ELL")
    assert contain?.("ÉCOLE", "école")
    refute contain?.("hello", "help")

    assert contain?.("50% off", "0% o")
    refute contain?.("500 off", "0% o")
    assert contain?.("a_b", "_b")
    refute contain?.("axb", "_b")
    assert contain?.("a\\b", "\\b")
    refute contain?.("ab", "\\b")
  end

  test "match? $contain finds an element of a list and matches no other type" do
    contain? = fn value, expected -> Filter.match?(%{"n" => value}, %{"n" => %{"$contain" => expected}}) end

    assert contain?.(["red", 12, true], "red")
    assert contain?.(["red", 12, true], 12)
    assert contain?.(["red", 12, true], true)
    refute contain?.(["red"], "re")
    refute contain?.(["RED"], "red")

    refute contain?.(12, "1")
    refute contain?.(true, "true")
    refute contain?.(%{"red" => 1}, "red")
    refute contain?.(nil, "")
  end

  test "to_sql $like matches string values only" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"name" => %{"$like" => "foo%"}}, 1)

    assert sql ==
             "CASE jsonb_typeof(metadata #> $1::text[]) " <>
               "WHEN 'string' THEN metadata #>> $1::text[] ILIKE $2 ELSE FALSE END"

    assert params == [["name"], "foo%"]
  end

  test "to_sql $contain wraps the value in substring wildcards" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"name" => %{"$contain" => "foo"}}, 1)
    assert sql =~ "metadata #>> $1::text[] ILIKE $2"
    assert params == [["name"], "%foo%", ["foo"]]
  end

  test "to_sql $contain matches a substring of a string or an element of an array" do
    assert {:ok, {sql, params}} = Filter.to_sql(%{"tags" => %{"$contain" => 12}}, 3)

    assert sql ==
             "CASE jsonb_typeof(metadata #> $3::text[]) " <>
               "WHEN 'string' THEN metadata #>> $3::text[] ILIKE $4 " <>
               "WHEN 'array' THEN metadata #> $3::text[] @> $5::jsonb ELSE FALSE END"

    assert params == [["tags"], "%12%", [12]]
  end

  test "to_sql $contain escapes %, _ and backslash in the value" do
    assert {:ok, {_sql, params}} = Filter.to_sql(%{"n" => %{"$contain" => "50%_\\"}}, 1)
    assert params == [["n"], "%50\\%\\_\\\\%", ["50%_\\"]]
  end

  test "to_sql numbers the parameters after $contain" do
    assert {:ok, {sql, params}} =
             Filter.to_sql(%{"$and" => [%{"tags" => %{"$contain" => "a"}}, %{"b" => 2}]}, 1)

    assert sql =~ "@> $3::jsonb"
    assert sql =~ "metadata #>> $4::text[] = $5"
    assert params == [["tags"], "%a%", ["a"], ["b"], "2"]

    assert {:ok, {sql, params}} = Filter.to_sql(%{"tags" => %{"$contain" => "a", "$ne" => "b"}}, 1)
    assert sql =~ "@> $3::jsonb"
    assert sql =~ "metadata #>> $4::text[] != $5"
    assert params == [["tags"], "%a%", ["a"], ["tags"], "b"]
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
