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

  describe "from_fields/1 with nullable fields" do
    test "a nullable enum lists nil once among its values" do
      schema =
        Fields.from_fields([
          {:priority, :string, enum: ["low", "high"], nullable: true},
          {:size, {:union, [:string, :integer]}, enum: ["small", 10, nil], nullable: true},
          {:status, :string, enum: ["open"]}
        ])

      assert schema.properties.priority == %{type: ["string", "null"], enum: ["low", "high", nil]}
      assert schema.properties.size.enum == ["small", 10, nil]
      assert schema.properties.status == %{type: "string", enum: ["open"]}
    end

    test "a JSON Schema map with string keys accepts null under its own keys" do
      schema =
        Fields.from_fields([
          {:region, %{"type" => "string", "enum" => ["eu", "us"]}, nullable: true},
          {:size, %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}]}, nullable: true}
        ])

      assert schema.properties.region == %{"type" => ["string", "null"], "enum" => ["eu", "us", nil]}

      assert schema.properties.size == %{
               "anyOf" => [%{"type" => "string"}, %{"type" => "integer"}, %{"type" => "null"}]
             }

      assert :ok = BeamWeaver.Core.Tool.validate_input(schema, %{region: nil, size: nil})

      assert {:error, %{message: "tool input is not in enum"}} =
               BeamWeaver.Core.Tool.validate_input(schema, %{region: "apac", size: nil})
    end

    test "a type that already allows null lists it once" do
      schema =
        Fields.from_fields([
          {:note, :null, nullable: true},
          {:kind, %{type: ["string", "null"]}, nullable: true}
        ])

      assert schema.properties.note == %{type: ["null"]}
      assert schema.properties.kind == %{type: ["string", "null"]}
    end
  end
end
