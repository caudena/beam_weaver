defmodule BeamWeaver.SchemaTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Schema

  defmodule PrimitiveFields do
    use BeamWeaver.Schema

    field(:name, :string)
    field(:enabled, :boolean)
  end

  defmodule NestedFields do
    use BeamWeaver.Schema

    field(:value, :string)
  end

  defmodule CompoundFields do
    use BeamWeaver.Schema

    field(:nested, NestedFields)
    field(:entries, {:array, NestedFields})
  end

  defmodule Ticket do
    use BeamWeaver.Schema

    field(:priority, :string, enum: ["low", "high"], nullable: true)
    field(:status, :string, enum: ["open", nil], nullable: true, required: false)
    field(:size, {:union, [:string, :integer]}, nullable: true, required: false)
    field(:note, :any, nullable: true, required: false)
  end

  test "a field type can be a JSON Schema map" do
    [{module, _bytecode}] =
      Code.compile_string("""
      defmodule BeamWeaver.SchemaTest.MapField do
        use BeamWeaver.Schema
        field :due, %{"type" => "string", "format" => "date"}
      end
      """)

    assert module.json_schema()["properties"]["due"] == %{"type" => "string", "format" => "date"}
  end

  test "module DSL resolves primitive atoms as JSON Schema types" do
    schema = PrimitiveFields.json_schema()

    assert schema["properties"]["name"] == %{"type" => "string"}
    assert schema["properties"]["enabled"] == %{"type" => "boolean"}
  end

  test "module DSL resolves nested schema modules and arrays" do
    nested_schema = NestedFields.json_schema()
    schema = CompoundFields.json_schema()

    assert schema["properties"]["nested"] == nested_schema
    assert schema["properties"]["entries"] == %{"type" => "array", "items" => nested_schema}
  end

  test "a nullable field accepts null, and its enum lists nil once" do
    properties = Ticket.json_schema()["properties"]

    assert properties["priority"] == %{"type" => ["string", "null"], "enum" => ["low", "high", nil]}
    assert properties["status"]["enum"] == ["open", nil]
    assert properties["size"] == %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}, %{"type" => "null"}]}
    assert properties["note"] == %{"anyOf" => [%{}, %{"type" => "null"}]}
  end

  describe "to_json_schema/1 field defaults" do
    test "emits an explicit empty-string default" do
      schema = Schema.to_json_schema({:object, [{:name, :string, [default: ""]}]})

      assert get_in(schema, ["properties", "name", "default"]) == ""
    end

    test "emits a non-empty default" do
      schema = Schema.to_json_schema({:object, [{:name, :string, [default: "hello"]}]})

      assert get_in(schema, ["properties", "name", "default"]) == "hello"
    end

    test "omits default when not declared" do
      schema = Schema.to_json_schema({:object, [{:name, :string, []}]})

      refute Map.has_key?(schema["properties"]["name"], "default")
    end
  end
end
