defmodule BeamWeaver.Tool.RendererTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Tool.Renderer

  describe "strict_json_schema/2" do
    test "preserves legitimate nil-valued user keys" do
      schema = %{
        "type" => "object",
        "title" => nil,
        "description" => nil,
        "properties" => %{"name" => %{"type" => "string"}}
      }

      result = Renderer.strict_json_schema(schema)

      assert Map.has_key?(result, "title")
      assert result["title"] == nil
      assert Map.has_key?(result, "description")
      assert result["description"] == nil
    end

    test "does not introduce structural placeholder keys for absent structural keywords" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}}
      }

      result = Renderer.strict_json_schema(schema)

      refute Map.has_key?(result, "items")
      refute Map.has_key?(result, "anyOf")
      refute Map.has_key?(result, "oneOf")
      refute Map.has_key?(result, "$defs")
      refute Map.has_key?(result, "definitions")
    end
  end
end
