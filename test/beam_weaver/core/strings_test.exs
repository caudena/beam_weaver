defmodule BeamWeaver.Core.StringsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Strings

  test "Postgres sanitization removes or replaces NUL bytes" do
    # Upstream reference:
    assert Strings.sanitize_for_postgres("Hello\x00world\x00test") == "Helloworldtest"
    assert Strings.sanitize_for_postgres("Hello\x00world\x00test", " ") == "Hello world test"
    assert Strings.sanitize_for_postgres("Hello world") == "Hello world"
    assert Strings.sanitize_for_postgres("") == ""
    assert Strings.sanitize_for_postgres("Hello\x00\x00\x00world", "-") == "Hello---world"
  end

  test "comma_list accepts any enumerable and mixed values" do
    # Upstream reference:
    assert Strings.comma_list([1, 2, 3]) == "1, 2, 3"
    assert Strings.comma_list(["a", "b", "c"]) == "a, b, c"
    assert Strings.comma_list(0..2) == "0, 1, 2"
    assert Strings.comma_list([]) == ""
    assert Strings.comma_list([1, "two", 3.0]) == "1, two, 3.0"
  end

  test "stringify_value and stringify_dict preserve nested content" do
    # Upstream reference:
    assert Strings.stringify_value("hello") == "hello"
    assert Strings.stringify_value(42) == "42"

    result = Strings.stringify_dict(%{"key" => "value", "number" => 123})
    assert result =~ "key: value"
    assert result =~ "number: 123"

    nested =
      Strings.stringify_value(%{
        "users" => [%{"name" => "Alice", "age" => 25}, %{"name" => "Bob", "age" => 30}],
        "metadata" => %{"total_users" => 2, "active" => true}
      })

    assert nested =~ "users:"
    assert nested =~ "name: Alice"
    assert nested =~ "name: Bob"
    assert nested =~ "metadata:"
    assert nested =~ "total_users: 2"
    assert nested =~ "active: true"

    mixed = Strings.stringify_value(["string", 42, %{"key" => "value"}, ["nested", "list"]])
    assert mixed =~ "string"
    assert mixed =~ "42"
    assert mixed =~ "key: value"
    assert mixed =~ "nested"
    assert mixed =~ "list"
  end
end
