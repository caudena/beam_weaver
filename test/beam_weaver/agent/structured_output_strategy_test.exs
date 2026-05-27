defmodule BeamWeaver.Agent.StructuredOutputStrategyTest do
  use ExUnit.Case, async: true

  # Native coverage for:
  # langchain/libs/langchain_v1/tests/unit_tests/agents/test_responses.py

  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Core.Message

  @person_schema %{
    "title" => "Person",
    "description" => "A structured person response.",
    "type" => "object",
    "required" => ["name", "age"],
    "properties" => %{
      "name" => %{"type" => "string"},
      "age" => %{"type" => "integer"},
      "email" => %{"type" => "string"}
    }
  }

  @custom_schema %{
    "title" => "CustomModel",
    "description" => "Custom schema description.",
    "type" => "object",
    "required" => ["value"],
    "properties" => %{"value" => %{"type" => "number"}}
  }

  test "tool strategy keeps schema specs and optional tool-message content" do
    strategy = StructuredOutput.tool(@person_schema)

    assert strategy.schema == @person_schema
    assert strategy.tool_message_content == nil
    assert [%{name: "Person", schema: @person_schema}] = strategy.schema_specs

    custom = StructuredOutput.tool(@person_schema, tool_message_content: "custom message")
    assert custom.tool_message_content == "custom message"
  end

  test "tool strategy supports explicit oneOf schema alternatives" do
    strategy = StructuredOutput.tool(%{"oneOf" => [@person_schema, @custom_schema]})

    assert Enum.map(strategy.schema_specs, & &1.name) == ["Person", "CustomModel"]
    assert Enum.map(strategy.schema_specs, & &1.schema) == [@person_schema, @custom_schema]
  end

  test "provider strategy keeps strict option and renders provider response_format opts" do
    strategy = StructuredOutput.provider(@person_schema, strict: true)

    assert strategy.schema == @person_schema
    assert strategy.strict == true
    assert strategy.schema_spec.strict == true

    assert [
             response_format: %{
               name: "Person",
               schema: @person_schema,
               strict: true,
               validator: validator
             }
           ] = StructuredOutput.provider_opts(strategy)

    assert is_function(validator, 1)
    assert :ok = validator.(%{"name" => "Ada", "age" => 37})
  end

  test "schema specs can override tool names and descriptions for generated tools" do
    spec =
      StructuredOutput.schema_spec(@person_schema,
        name: "custom_tool_name",
        description: "Custom tool description"
      )

    assert spec.name == "custom_tool_name"
    assert spec.description == "Custom tool description"

    assert [%{name: "custom_tool_name", description: "Custom tool description"}] =
             StructuredOutput.setup_tools(%StructuredOutput.ToolStrategy{
               schema: @person_schema,
               schema_specs: [spec]
             })
  end

  test "tool strategy parses valid tool-call payloads and returns tagged validation errors" do
    spec = StructuredOutput.schema_spec(@person_schema)

    assert {:ok, %{"name" => "John", "age" => 30}} =
             StructuredOutput.parse(spec, %{"name" => "John", "age" => 30})

    assert {:error, %{type: :structured_output_validation_error, details: %{missing: ["name"]}}} =
             StructuredOutput.parse(spec, %{"age" => 30})

    assert {:error, %{type: :structured_output_validation_error, details: %{key: "age"}}} =
             StructuredOutput.parse(spec, %{"name" => "John", "age" => "thirty"})
  end

  test "provider strategy parses JSON message text and mixed text content lists" do
    strategy = StructuredOutput.provider(@person_schema)

    assert {:ok, %{structured_response: %{"name" => "John", "age" => 30}}} =
             StructuredOutput.handle_model_output(
               Message.assistant(~s({"name":"John","age":30})),
               strategy
             )

    message =
      Message.assistant([
        ~s({"name":),
        %{"content" => ~s("Jane",)},
        %{"type" => "text", "text" => ~s("age":31})}
      ])

    assert {:ok, %{structured_response: %{"name" => "Jane", "age" => 31}}} =
             StructuredOutput.handle_model_output(message, strategy)
  end

  test "provider strategy returns tagged parse and validation errors" do
    strategy = StructuredOutput.provider(@person_schema)

    assert {:error, %{type: :structured_output_parse_error}} =
             StructuredOutput.handle_model_output(Message.assistant("invalid json"), strategy)

    assert {:error, %{type: :structured_output_validation_error}} =
             StructuredOutput.handle_model_output(Message.assistant(~s({"age":30})), strategy)
  end
end
