defmodule BeamWeaver.Graph.ValidationNodeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Nodes.ValidationNode

  test "validates tool calls without executing tools" do
    parent = self()

    select_number =
      Tool.from_function!(
        name: "select_number",
        description: "Select a number",
        input_schema: %{
          "required" => ["some_val", "some_other_val"],
          "properties" => %{
            "some_val" => %{"type" => "integer"},
            "some_other_val" => %{"type" => "string"}
          }
        },
        handler: fn _input, _opts ->
          send(parent, :tool_executed)
          "should not run"
        end
      )

    node = ValidationNode.new([select_number])

    input = %{
      messages: [
        Message.user("select"),
        Message.assistant("",
          tool_calls: [
            %{
              id: "valid",
              name: "select_number",
              args: %{"some_val" => 37, "some_other_val" => "ok"}
            },
            %{
              id: "invalid",
              name: "select_number",
              args: %{"some_val" => "nope", "some_other_val" => "ok"}
            }
          ]
        )
      ]
    }

    assert %{messages: [valid, invalid]} = ValidationNode.invoke(node, input)

    assert valid.role == :tool
    assert valid.tool_call_id == "valid"
    assert valid.name == "select_number"
    assert valid.metadata.status == "success"
    assert BeamWeaver.JSON.decode!(valid.content) == %{"some_other_val" => "ok", "some_val" => 37}

    assert invalid.role == :tool
    assert invalid.tool_call_id == "invalid"
    assert invalid.metadata.status == "error"
    assert invalid.metadata.is_error == true
    assert invalid.metadata.error_type == :invalid_input
    assert invalid.content =~ "invalid type"

    refute_receive :tool_executed
  end

  test "returns list output for list input and reports unknown schemas" do
    node = ValidationNode.new([{"known", %{"required" => ["value"]}}])

    assert [unknown, missing] =
             ValidationNode.invoke(node, [
               Message.assistant("",
                 tool_calls: [
                   %{id: "unknown", name: "unknown", args: %{}},
                   %{id: "missing", name: "known", args: %{}}
                 ]
               )
             ])

    assert unknown.metadata.status == "error"
    assert unknown.metadata.error_type == :unknown_tool
    assert unknown.name == "unknown"

    assert missing.metadata.status == "error"
    assert missing.metadata.error_type == :invalid_input
    assert missing.name == "known"
  end

  test "can suppress success messages for generated agent loop validation" do
    node = ValidationNode.new([{"known", %{"required" => ["value"]}}], success: :silent)

    assert [invalid] =
             ValidationNode.invoke(node, [
               Message.assistant("",
                 tool_calls: [
                   %{id: "valid", name: "known", args: %{"value" => "ok"}},
                   %{id: "invalid", name: "known", args: %{}}
                 ]
               )
             ])

    assert invalid.role == :tool
    assert invalid.tool_call_id == "invalid"
    assert invalid.metadata.status == "error"
  end
end
