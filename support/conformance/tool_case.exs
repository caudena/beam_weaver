defmodule BeamWeaver.TestSupport.Conformance.ToolCase do
  @moduledoc """
  Shared ExUnit checks for `BeamWeaver.Core.Tool` implementations.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Core.Tool
      alias BeamWeaver.TestSupport.Conformance.Subject

      @beamweaver_subject Subject.new(opts, :tool)

      test "tool exposes name, description, and input schema" do
        tool = build_subject()

        assert Tool.name(tool) != ""
        assert Tool.description(tool) != ""
        assert is_map(Tool.input_schema(tool))
      end

      test "tool example input satisfies declared required schema and invokes successfully" do
        tool = build_subject()

        assert :ok = Tool.validate_input(Tool.input_schema(tool), fixture(:input))
        assert {:ok, _result} = Tool.invoke(tool, fixture(:input))
      end

      test "tool reports missing required input as a tagged error" do
        tool = build_subject()
        required = Tool.input_schema(tool)[:required] || Tool.input_schema(tool)["required"] || []

        if required != [] do
          missing_input =
            Enum.reduce(required, fixture(:input), fn key, input ->
              Map.drop(input, equivalent_keys(key))
            end)

          assert {:error, error} = Tool.invoke(tool, missing_input)
          assert error.type == :invalid_input
          assert error.details.missing != []
        end
      end

      test "tool validates declared JSON-schema property types before invocation" do
        tool = build_subject()
        schema = Tool.input_schema(tool)
        properties = schema[:properties] || schema["properties"] || %{}

        case Enum.find(properties, fn {_key, spec} ->
               is_map(spec) and (spec[:type] || spec["type"])
             end) do
          nil ->
            assert :ok

          {key, spec} ->
            bad_value = wrong_type(spec[:type] || spec["type"])
            input = Map.put(fixture(:input), key, bad_value)
            assert {:error, error} = Tool.invoke(tool, input)
            assert error.type == :invalid_input
        end
      end

      if Subject.capability?(@beamweaver_subject, :nested_schema) do
        test "tool validates nested object and array schemas before invocation" do
          tool = build_subject()
          invalid_input = fixture(:nested_invalid_input)

          assert {:error, error} = Tool.invoke(tool, invalid_input)
          assert error.type == :invalid_input
          assert error.details.key || error.details.path
        end
      end

      if Subject.capability?(@beamweaver_subject, :provider_name_validation) do
        test "provider rendering rejects unsafe provider-facing names at render time" do
          tool = build_subject()

          assert {:error, error} = BeamWeaver.Tool.Renderer.openai_function(tool)
          assert error.type == :invalid_tool_name
        end
      end

      if Subject.capability?(@beamweaver_subject, :provider_rendering) do
        test "tool renders to provider-safe OpenAI schema" do
          tool = build_subject()

          assert {:ok, rendered} = BeamWeaver.Tool.Renderer.openai_function(tool)
          assert rendered["name"] == Tool.name(tool)
          assert rendered["description"] == Tool.description(tool)
          assert is_map(rendered["parameters"])
        end
      end

      if Subject.capability?(@beamweaver_subject, :injected_args) do
        test "provider-facing schema hides injected runtime arguments" do
          tool = build_subject()
          raw = Tool.raw_input_schema(tool)
          visible = Tool.input_schema(tool)

          assert raw != visible
          refute Map.has_key?(visible[:properties] || visible["properties"] || %{}, :runtime)
          refute Map.has_key?(visible[:properties] || visible["properties"] || %{}, "runtime")
        end
      end

      if Subject.capability?(@beamweaver_subject, :artifacts) do
        test "tool exposes response format, output schema, metadata, and artifacts" do
          tool = build_subject()

          assert Tool.response_format(tool) != nil
          assert is_map(Tool.output_schema(tool))
          assert is_map(Tool.metadata(tool))
        end
      end

      defp build_subject, do: Subject.build(@beamweaver_subject)
      defp fixture(key, default \\ nil), do: Subject.fixture(@beamweaver_subject, key, default)

      defp equivalent_keys(key) when is_atom(key), do: [key, Atom.to_string(key)]
      defp equivalent_keys(key) when is_binary(key), do: [key]
      defp equivalent_keys(key), do: [key]

      defp wrong_type("string"), do: 123
      defp wrong_type(:string), do: 123
      defp wrong_type("integer"), do: "not integer"
      defp wrong_type(:integer), do: "not integer"
      defp wrong_type("number"), do: "not number"
      defp wrong_type(:number), do: "not number"
      defp wrong_type("boolean"), do: "not boolean"
      defp wrong_type(:boolean), do: "not boolean"
      defp wrong_type("object"), do: "not object"
      defp wrong_type(:object), do: "not object"
      defp wrong_type("array"), do: "not array"
      defp wrong_type(:array), do: "not array"
      defp wrong_type(_type), do: nil
    end
  end
end
