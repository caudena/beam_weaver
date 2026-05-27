defmodule BeamWeaver.OpenAI.ToolCallingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Messages.Utils
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.OpenAI.ToolCalling

  defmodule FakeCall do
    defstruct [:data]
  end

  test "builds OpenAI built-in tool declarations from idiomatic helpers" do
    assert ToolCalling.web_search() == %{"type" => "web_search_preview"}

    assert ToolCalling.file_search(["vs_123"], max_num_results: 3) == %{
             "type" => "file_search",
             "vector_store_ids" => ["vs_123"],
             "max_num_results" => 3
           }

    assert ToolCalling.code_interpreter(%{type: :auto}) == %{
             "type" => "code_interpreter",
             "container" => %{"type" => "auto"}
           }

    assert ToolCalling.image_generation(
             quality: "low",
             output_format: "jpeg",
             output_compression: 100,
             size: "1024x1024"
           ) == %{
             "type" => "image_generation",
             "quality" => "low",
             "output_format" => "jpeg",
             "output_compression" => 100,
             "size" => "1024x1024"
           }

    assert ToolCalling.custom("execute_code", description: "Execute python code.") == %{
             "type" => "custom",
             "name" => "execute_code",
             "description" => "Execute python code."
           }
  end

  test "builds MCP and tool-search declarations with nested option normalization" do
    assert ToolCalling.mcp("deepwiki", "https://mcp.deepwiki.com/mcp",
             require_approval: %{always: %{tool_names: ["read_wiki_structure"]}}
           ) == %{
             "type" => "mcp",
             "server_label" => "deepwiki",
             "server_url" => "https://mcp.deepwiki.com/mcp",
             "require_approval" => %{
               "always" => %{"tool_names" => ["read_wiki_structure"]}
             }
           }

    assert ToolCalling.tool_search(mode: :server) == %{
             "type" => "tool_search",
             "mode" => "server"
           }
  end

  test "adds OpenAI tool-search fields to BeamWeaver function tool declarations" do
    tool =
      Tool.from_function!(
        name: "get_weather",
        description: "Get the current weather for a location.",
        input_schema: %{
          type: "object",
          properties: %{location: %{type: "string"}},
          required: [:location],
          additionalProperties: false
        },
        handler: fn input, _opts -> input end
      )

    assert ToolCalling.function(tool, defer_loading: true, strict: true) == %{
             "type" => "function",
             "name" => "get_weather",
             "description" => "Get the current weather for a location.",
             "parameters" => %{
               "type" => "object",
               "properties" => %{"location" => %{"type" => "string"}},
               "required" => ["location"],
               "additionalProperties" => false
             },
             "defer_loading" => true,
             "strict" => true
           }
  end

  test "strict BeamWeaver function rendering closes nested provider schemas" do
    tool =
      Tool.from_function!(
        name: "search_docs",
        description: "Search support docs.",
        input_schema: %{
          type: "object",
          properties: %{
            query: %{type: "string"},
            filters: %{
              type: "object",
              properties: %{
                section: %{type: "string", enum: ["billing", "support"]},
                metadata: %{type: ["object", "null"]}
              },
              required: [:section]
            },
            payload: %{
              anyOf: [
                %{type: "object", properties: %{id: %{type: "string"}}},
                %{type: "null"}
              ]
            }
          },
          required: [:query]
        },
        handler: fn input, _opts -> input end
      )

    rendered = ToolCalling.function(tool, strict: true)

    assert rendered["strict"] == true
    assert rendered["parameters"]["additionalProperties"] == false
    assert rendered["parameters"]["required"] == ["query", "filters", "payload"]

    assert rendered["parameters"]["properties"]["filters"]["additionalProperties"] == false
    assert rendered["parameters"]["properties"]["filters"]["required"] == ["section", "metadata"]

    assert rendered["parameters"]["properties"]["filters"]["properties"]["metadata"][
             "additionalProperties"
           ] == false

    assert rendered["parameters"]["properties"]["payload"]["anyOf"] == [
             %{
               "type" => "object",
               "properties" => %{"id" => %{"type" => "string"}},
               "additionalProperties" => false,
               "required" => ["id"]
             },
             %{"type" => "null"}
           ]
  end

  test "OpenAI function rendering dereferences schemas and preserves enum defaults" do
    tool =
      Tool.from_function!(
        name: "update_status",
        description: "Update status.",
        input_schema: %{
          type: "object",
          properties: %{
            status: %{"$ref" => "#/$defs/Status"},
            assignee: %{
              "$ref" => "#/$defs/User",
              description: "Optional owner"
            }
          },
          required: [:status],
          "$defs": %{
            Status: %{
              type: "string",
              enum: ["pending", "completed", "error"],
              default: "pending"
            },
            User: %{type: "string", minLength: 1}
          }
        },
        handler: fn input, _opts -> input end
      )

    assert ToolCalling.function(tool) == %{
             "type" => "function",
             "name" => "update_status",
             "description" => "Update status.",
             "parameters" => %{
               "type" => "object",
               "properties" => %{
                 "status" => %{
                   "type" => "string",
                   "enum" => ["pending", "completed", "error"],
                   "default" => "pending"
                 },
                 "assignee" => %{
                   "type" => "string",
                   "minLength" => 1,
                   "description" => "Optional owner"
                 }
               },
               "required" => ["status"],
               "$defs" => %{
                 "Status" => %{
                   "type" => "string",
                   "enum" => ["pending", "completed", "error"],
                   "default" => "pending"
                 },
                 "User" => %{"type" => "string", "minLength" => 1}
               }
             }
           }
  end

  test "normalizes Responses API tool maps without wrapping built-ins or namespaces" do
    chat_completions_function = %{
      "type" => "function",
      "function" => %{
        "name" => "get_weather",
        "description" => "Get weather.",
        "parameters" => %{"type" => "object"}
      },
      "defer_loading" => true
    }

    namespace_tool = %{
      type: :namespace,
      name: "crm",
      tools: [
        %{
          type: :function,
          name: "list_orders",
          defer_loading: true,
          parameters: %{type: :object}
        }
      ]
    }

    assert ToolCalling.to_openai_tools([
             chat_completions_function,
             ToolCalling.tool_search(),
             namespace_tool
           ]) == [
             %{
               "type" => "function",
               "name" => "get_weather",
               "description" => "Get weather.",
               "parameters" => %{"type" => "object"},
               "defer_loading" => true
             },
             %{"type" => "tool_search"},
             %{
               "type" => "namespace",
               "name" => "crm",
               "tools" => [
                 %{
                   "type" => "function",
                   "name" => "list_orders",
                   "defer_loading" => true,
                   "parameters" => %{"type" => "object"}
                 }
               ]
             }
           ]
  end

  test "omits runtime-injected tool arguments from OpenAI function declarations" do
    tool =
      Tool.from_function!(
        name: "search",
        description: "Search with runtime state",
        input_schema: %{
          type: "object",
          properties: %{
            query: %{type: "string"},
            state: %{type: "object"},
            tool_call_id: %{type: "string"}
          },
          required: [:query, :state, :tool_call_id],
          additionalProperties: false
        },
        injected: [state: :state, tool_call_id: :tool_call_id],
        handler: fn input, _opts -> input end
      )

    assert ToolCalling.function(tool) == %{
             "type" => "function",
             "name" => "search",
             "description" => "Search with runtime state",
             "parameters" => %{
               "type" => "object",
               "properties" => %{"query" => %{"type" => "string"}},
               "required" => ["query"],
               "additionalProperties" => false
             }
           }
  end

  test "builds native few-shot example messages for tool calls" do
    messages =
      ToolCalling.example_messages(
        "This is an example",
        [
          %FakeCall{data: "ToolCall1"},
          %{name: "FakeCall", args: %{data: "ToolCall2"}}
        ],
        ids: ["call_one", "call_two"],
        tool_outputs: ["Output1", "Output2"],
        ai_response: "The output is Output2"
      )

    assert [
             %Message{role: :user, content: "This is an example"},
             %Message{role: :assistant, content: "", tool_calls: assistant_calls},
             %Message{role: :tool, content: "Output1", tool_call_id: "call_one"},
             %Message{role: :tool, content: "Output2", tool_call_id: "call_two"},
             %Message{role: :assistant, content: "The output is Output2", tool_calls: []}
           ] = messages

    assert assistant_calls == [
             %ToolCall{id: "call_one", name: "FakeCall", args: %{"data" => "ToolCall1"}},
             %ToolCall{id: "call_two", name: "FakeCall", args: %{"data" => "ToolCall2"}}
           ]

    assert {:ok, openai_messages} = Utils.convert_to_openai_messages(messages)

    assert %{
             "role" => "assistant",
             "content" => "",
             "tool_calls" => [
               %{
                 "id" => "call_one",
                 "type" => "function",
                 "function" => %{"name" => "FakeCall", "arguments" => "{\"data\":\"ToolCall1\"}"}
               },
               %{
                 "id" => "call_two",
                 "type" => "function",
                 "function" => %{"name" => "FakeCall", "arguments" => "{\"data\":\"ToolCall2\"}"}
               }
             ]
           } = Enum.at(openai_messages, 1)
  end

  test "tool-call examples include empty assistant tool call messages without outputs" do
    assert [
             %Message{role: :user, content: "No calls"},
             %Message{role: :assistant, content: "", tool_calls: []}
           ] = ToolCalling.example_messages("No calls", [])
  end
end
