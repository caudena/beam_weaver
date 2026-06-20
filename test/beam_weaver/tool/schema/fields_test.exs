defmodule BeamWeaver.Tool.Schema.FieldsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Tool.Schema.Fields

  describe "from_fields/1 with nested objects" do
    test "accepts 2-tuple inner field declarations inside {:object, fields}" do
      schema =
        Fields.from_fields([
          {:filters, {:object, [{:a, :string}, {:b, :integer}]}, []}
        ])

      assert %{
               type: "object",
               properties: %{
                 filters: %{
                   type: "object",
                   properties: %{
                     a: %{type: "string"},
                     b: %{type: "integer"}
                   },
                   required: [:a, :b]
                 }
               }
             } = schema
    end

    test "accepts mixed 2-tuple and 3-tuple inner declarations" do
      schema =
        Fields.from_fields([
          {:filters, {:object, [{:a, :string}, {:b, :integer, required: false}]}, []}
        ])

      filters = schema.properties.filters
      assert filters.required == [:a]
      assert filters.properties.a == %{type: "string"}
      assert filters.properties.b == %{type: "integer"}
    end
  end
end
