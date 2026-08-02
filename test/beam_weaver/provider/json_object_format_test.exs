defmodule BeamWeaver.Provider.JsonObjectFormatTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.JsonObjectFormat

  test "normalizes JSON-object formats without injecting an instruction" do
    assert {:ok, %{"type" => "json_object"}, nil} =
             JsonObjectFormat.normalize(%{type: :json_object})

    assert {:ok, %{"type" => "json_object"}, nil} =
             JsonObjectFormat.normalize(%{"type" => :json_object})

    assert {:ok, nil, nil} = JsonObjectFormat.normalize(nil)
  end

  test "renders schema contracts and inserts them after leading system messages" do
    schema = %{
      type: "object",
      required: ["answer"],
      properties: %{answer: %{type: "string"}}
    }

    assert {:ok, %{"type" => "json_object"}, instruction} =
             JsonObjectFormat.normalize(%{name: "Answer", schema: schema, strict: false})

    assert instruction["content"] =~ "Validate against this schema."
    assert instruction["content"] =~ "Required keys: answer"
    assert instruction["content"] =~ ~s("answer")

    messages = [
      %{"role" => "system", "content" => "existing"},
      %{"role" => "user", "content" => "question"}
    ]

    assert JsonObjectFormat.inject_instruction(messages, instruction) == [
             hd(messages),
             instruction,
             List.last(messages)
           ]
  end

  test "recursively normalizes atom schema keys and values before rendering" do
    schema = %{
      type: :object,
      required: [:answer],
      properties: %{
        answer: %{type: :string, enum: [:yes, :no]},
        details: %{
          type: :object,
          properties: %{attempts: %{type: :integer}}
        }
      }
    }

    assert {:ok, %{"type" => "json_object"}, %{"content" => content}} =
             JsonObjectFormat.normalize(%{name: "Answer", schema: schema})

    [_, rendered_schema] = String.split(content, "JSON Schema:\n", parts: 2)

    assert BeamWeaver.JSON.decode!(rendered_schema) == %{
             "type" => "object",
             "required" => ["answer"],
             "properties" => %{
               "answer" => %{"type" => "string", "enum" => ["yes", "no"]},
               "details" => %{
                 "type" => "object",
                 "properties" => %{"attempts" => %{"type" => "integer"}}
               }
             }
           }
  end

  test "returns the configured provider error for unsupported formats" do
    assert {:error, %Error{} = error} =
             JsonObjectFormat.normalize(%{type: "json_schema"},
               error_message: "JSON object only",
               error_details: %{provider: :test}
             )

    assert error.type == :invalid_response_format
    assert error.message == "JSON object only"
    assert error.details.provider == :test
    assert error.details.supported == [%{"type" => "json_object"}]
  end
end
