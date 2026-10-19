defmodule BeamWeaver.Anthropic.ChatModel.RequestBuilderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.ChatModel
  alias BeamWeaver.Anthropic.ChatModel.RequestBuilder
  alias BeamWeaver.Core.Message

  test "tools: nil is treated as no tools instead of raising" do
    model = ChatModel.new(model: "claude-sonnet-4-6")

    assert {:ok, body} = RequestBuilder.request_body(model, [Message.user("hi")], tools: nil)
    refute Map.has_key?(body, "tools")

    assert {:ok, count_body} = RequestBuilder.count_tokens_body(model, [Message.user("hi")], tools: nil)
    refute Map.has_key?(count_body, "tools")
  end

  test "response schemas close nested objects without changing optional fields" do
    model = ChatModel.new(model: "claude-haiku-4-5")

    schema = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "details" => %{"type" => "object", "properties" => %{"reason" => %{"type" => "string"}}},
        "items" => %{"type" => "array", "items" => %{"type" => "object", "properties" => %{}}}
      },
      "required" => ["name"]
    }

    assert {:ok, body} =
             RequestBuilder.request_body(model, [Message.user("hello")],
               response_format: %{name: "answer", schema: schema}
             )

    actual = body["output_config"]["format"]["schema"]
    assert actual["additionalProperties"] == false
    assert actual["properties"]["details"]["additionalProperties"] == false
    assert actual["properties"]["items"]["items"]["additionalProperties"] == false
    assert actual["required"] == ["name"]
    refute Map.has_key?(actual["properties"]["details"], "required")
  end
end
