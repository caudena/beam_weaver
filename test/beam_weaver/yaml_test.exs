defmodule BeamWeaver.YAMLTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.YAML

  test "decodes scalars, sequences and mappings into plain terms" do
    yaml = """
    text: hello
    empty: ''
    count: 3
    ratio: 0.5
    enabled: true
    missing: ~
    codes: [1, 2]
    nested: {inner: [a, b]}
    none: {}
    """

    assert {:ok,
            %{
              "text" => "hello",
              "empty" => "",
              "count" => 3,
              "ratio" => 0.5,
              "enabled" => true,
              "missing" => nil,
              "codes" => [1, 2],
              "nested" => %{"inner" => ["a", "b"]},
              "none" => %{}
            }} = YAML.decode(yaml)
  end

  test "a key keeps its YAML type unless string keys are asked for" do
    assert {:ok, %{1 => "one", true => "yes"}} = YAML.decode("1: one\ntrue: yes\n")
    assert {:ok, %{"1" => "one", "true" => "yes"}} = YAML.decode("1: one\ntrue: yes\n", string_keys: true)
  end

  test "a repeated key keeps its last value, or is an error with unique keys" do
    assert {:ok, %{"a" => 2}} = YAML.decode("a: 1\na: 2\n")
    assert {:error, :duplicate_keys} = YAML.decode("a: 1\na: 2\n", unique_keys: true)
    assert {:error, :duplicate_keys} = YAML.decode("a:\n  - b: 1\n    b: 2\n", unique_keys: true)
    assert {:ok, %{"a" => [%{"b" => 1}, %{"b" => 2}]}} = YAML.decode("a:\n  - b: 1\n  - b: 2\n", unique_keys: true)
  end

  test "with unique keys an empty mapping is still an empty map" do
    assert {:ok, %{"a" => %{}, "b" => []}} = YAML.decode("a: {}\nb: []\n", unique_keys: true)
  end

  test "anything but exactly one document is an error" do
    assert {:error, :not_one_document} = YAML.decode("")
    assert {:error, :not_one_document} = YAML.decode("a: 1\n---\nb: 2\n")
  end

  test "malformed YAML is an error, not an exception" do
    assert {:error, {:invalid, reason}} = YAML.decode("a: [\nb: 2\n")
    assert is_binary(reason)
  end
end
