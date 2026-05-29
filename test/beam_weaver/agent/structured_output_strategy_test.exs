defmodule BeamWeaver.Agent.StructuredOutputStrategyTest do
  use ExUnit.Case, async: true

  # Native coverage for:
  # langchain/libs/langchain_v1/tests/unit_tests/agents/test_responses.py

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Core.Error
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

  defmodule InvalidProviderStructuredAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Agent.StructuredOutput
    alias BeamWeaver.Models.FakeChatModel

    @schema %{
      "title" => "Person",
      "type" => "object",
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string"}}
    }

    model(%FakeChatModel{structured_response: %{"age" => 37}})
    response_format(StructuredOutput.provider(@schema, strict: true))
  end

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

  test "provider strategy loads unloaded module schemas before using fallback object schema" do
    module = BeamWeaver.Agent.StructuredOutputStrategyTest.UnloadedJsonSchemaFixture
    tmp_dir = Path.join(System.tmp_dir!(), "beam_weaver_schema_fixture_#{System.unique_integer([:positive])}")
    source_file = Path.join(tmp_dir, "unloaded_json_schema_fixture.ex")

    :code.purge(module)
    :code.delete(module)
    File.mkdir_p!(tmp_dir)

    File.write!(source_file, """
    defmodule #{inspect(module)} do
      def json_schema do
        %{
          "title" => "FixtureSchema",
          "type" => "object",
          "required" => ["value"],
          "properties" => %{"value" => %{"type" => "string"}}
        }
      end
    end
    """)

    assert {_output, 0} = System.cmd("elixirc", ["-o", tmp_dir, source_file], stderr_to_stdout: true)
    true = Code.prepend_path(String.to_charlist(tmp_dir))

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      Code.delete_path(String.to_charlist(tmp_dir))
      File.rm_rf(tmp_dir)
    end)

    assert :code.is_loaded(module) == false

    strategy = StructuredOutput.provider(module, name: "fixture_response", strict: true)

    assert strategy.schema_spec.name == "fixture_response"
    assert strategy.schema_spec.json_schema["title"] == "FixtureSchema"
    assert strategy.schema_spec.json_schema["required"] == ["value"]

    assert [
             response_format: %{
               schema: %{"required" => ["value"]},
               validator: validator
             }
           ] = StructuredOutput.provider_opts(strategy)

    assert :ok = validator.(%{"value" => "ok"})
  end

  test "provider strategy surfaces schema module load failures" do
    module = BeamWeaver.Agent.StructuredOutputStrategyTest.UnloadableJsonSchemaFixture
    tmp_dir = compile_on_load_failure_schema!(module, "beam_weaver_unloadable_provider_schema")

    on_exit(fn -> unload_schema_module(module, tmp_dir) end)

    assert_raise ArgumentError, ~r/:on_load_failure/, fn ->
      StructuredOutput.provider(module, name: "bad_response")
    end
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

  test "agent structured-output validation errors include request and response diagnostics" do
    assert {:error,
            %Error{
              type: :structured_output_validation_error,
              details: %{
                missing: ["name"],
                model_request: request,
                model_response: response
              }
            }} =
             Agent.invoke(InvalidProviderStructuredAgent, %{
               messages: [Message.user("return a person with key sk-live-secret")]
             })

    assert request.model == "chat"
    assert [%{role: :user, content: user_content}] = request.messages
    assert user_content =~ "return a person"
    refute user_content =~ "sk-live-secret"
    assert request.response_format.name == "Person"
    assert request.response_format.schema["required"] == ["name"]
    assert response.content =~ ~s("age")
    assert response.content =~ "37"
  end

  defp compile_on_load_failure_schema!(module, prefix) do
    tmp_dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    source_file = Path.join(tmp_dir, "unloadable_schema_fixture.ex")

    :code.purge(module)
    :code.delete(module)
    File.mkdir_p!(tmp_dir)

    File.write!(source_file, """
    defmodule #{inspect(module)} do
      @on_load :boom

      def boom, do: :erlang.error(:on_load_failed)

      def json_schema, do: %{"type" => "object"}
    end
    """)

    assert {_output, 0} = System.cmd("elixirc", ["-o", tmp_dir, source_file], stderr_to_stdout: true)
    true = Code.prepend_path(String.to_charlist(tmp_dir))
    tmp_dir
  end

  defp unload_schema_module(module, tmp_dir) do
    :code.purge(module)
    :code.delete(module)
    Code.delete_path(String.to_charlist(tmp_dir))
    File.rm_rf(tmp_dir)
  end
end
