defmodule BeamWeaver.Agent.StructuredOutput.SchemaTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.StructuredOutput.Schema

  test "oneOf variants without titles get distinct spec names" do
    schema = %{"oneOf" => [%{"type" => "object"}, %{"type" => "object"}]}

    names = schema |> Schema.schema_specs() |> Enum.map(& &1.name)

    assert length(names) == 2
    assert names == Enum.uniq(names)
  end

  test "oneOf variants keep their titles when present" do
    schema = %{"oneOf" => [%{"title" => "Cat", "type" => "object"}, %{"title" => "Dog", "type" => "object"}]}

    assert ["Cat", "Dog"] = schema |> Schema.schema_specs() |> Enum.map(& &1.name)
  end

  test "a null-typed property accepts only null" do
    spec =
      BeamWeaver.Agent.StructuredOutput.schema_spec(%{
        "title" => "Gone",
        "type" => "object",
        "properties" => %{"gone" => %{"type" => "null"}},
        "required" => ["gone"]
      })

    assert {:error, %{type: :structured_output_validation_error}} =
             BeamWeaver.Agent.StructuredOutput.validate_data(spec, %{"gone" => "x"})

    assert :ok = BeamWeaver.Agent.StructuredOutput.validate_data(spec, %{"gone" => nil})
  end
end
