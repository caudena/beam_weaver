defmodule BeamWeaver.SchemaTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Schema

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
