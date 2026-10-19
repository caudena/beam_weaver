defmodule BeamWeaver.Schema.ValidatorTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Schema.Validator

  defmodule Triage do
    use BeamWeaver.Schema

    field :category, :string, enum: ["shipping", "billing", "other"]
    field :priority, :string, enum: ["low", "high"]
  end

  test "checks required keys, and that the value is an object" do
    schema = %{
      "type" => "object",
      "required" => ["answer"],
      "properties" => %{"answer" => %{"type" => "string"}}
    }

    assert :ok = Validator.validate(schema, %{"answer" => "yes"})

    assert {:error, %Error{type: :schema_validation_error, details: %{missing: ["answer"]}}} =
             Validator.validate(schema, %{"other" => "no"})

    assert {:error, %Error{type: :schema_validation_error, message: "parsed output must be an object"}} =
             Validator.validate(schema, ["not", "object"])
  end

  test "checks property types" do
    schema = %{
      "type" => "object",
      "required" => ["answer", "score"],
      "properties" => %{"answer" => %{"type" => "string"}, "score" => %{"type" => "integer"}}
    }

    assert :ok = Validator.validate(schema, %{"answer" => "yes", "score" => 7})

    assert {:error, %Error{details: %{key: "score", expected: "integer", actual: ~s("7")}}} =
             Validator.validate(schema, %{"answer" => "yes", "score" => "7"})
  end

  test "checks enums, from a map or a schema module's declaration" do
    schema = Triage.json_schema()

    assert :ok = Validator.validate(schema, %{"category" => "billing", "priority" => "low"})

    assert {:error, %Error{message: "parsed output field is not in enum", details: %{key: "category", actual: "toys"}}} =
             Validator.validate(schema, %{"category" => "toys", "priority" => "low"})

    assert {:error, %Error{details: %{missing: ["priority"]}}} = Validator.validate(schema, %{"category" => "billing"})
  end

  test "matches keys as strings, so atom and string keys mix" do
    schema = %{type: :object, required: [:answer], properties: %{answer: %{type: :string}}}

    assert :ok = Validator.validate(schema, %{"answer" => "yes"})
    assert :ok = Validator.validate(%{"required" => ["answer"]}, %{answer: "yes"})
    assert {:error, %Error{details: %{key: :answer}}} = Validator.validate(schema, %{"answer" => 1})
  end

  test "an optional property may be absent, and a property without a type takes any value" do
    schema = %{"type" => "object", "properties" => %{"note" => %{"type" => "string"}, "extra" => %{}}}

    assert :ok = Validator.validate(schema, %{})
    assert :ok = Validator.validate(schema, %{"extra" => [1]})
  end
end
