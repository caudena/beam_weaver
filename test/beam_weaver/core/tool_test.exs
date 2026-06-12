defmodule BeamWeaver.Core.ToolTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolResult

  test "validates required input before invoking a tool handler" do
    tool =
      Tool.from_function!(
        name: "adder",
        description: "Adds two numbers",
        input_schema: %{required: [:a, :b]},
        handler: fn input, _opts -> input.a + input.b end
      )

    assert {:error, error} = Tool.invoke(tool, %{a: 1})
    assert error.type == :invalid_input
    assert error.details.missing == [:b]
  end

  test "normalizes handler errors to tagged core errors" do
    tool =
      Tool.from_function!(
        name: "exploder",
        description: "Raises",
        input_schema: %{required: []},
        handler: fn _input, _opts -> raise "boom" end
      )

    assert {:error, error} = Tool.invoke(tool, %{})
    assert error.type == :tool_exception
    assert error.message =~ "boom"
  end

  test "tool error handling policies can return native content or error tool messages" do
    bool_handler =
      Tool.from_function!(
        name: "bool_exploder",
        description: "Raises",
        input_schema: %{type: "object", required: []},
        handle_tool_error: true,
        handler: fn _input, _opts -> raise "boom" end
      )

    assert {:ok, "boom"} = Tool.invoke(bool_handler, %{})

    string_handler =
      Tool.from_function!(
        name: "string_exploder",
        description: "Raises",
        input_schema: %{type: "object", required: []},
        handle_tool_error: "handled",
        handler: fn _input, _opts -> raise "boom" end
      )

    assert {:ok, "handled"} = Tool.invoke(string_handler, %{})
    assert {:ok, "handled"} = string_handler |> Tool.async_invoke(%{}) |> Async.await()

    callable_handler =
      Tool.from_function!(
        name: "callable_exploder",
        description: "Raises",
        input_schema: %{type: "object", required: []},
        handle_tool_error: fn error -> "callable:#{error.type}:#{error.message}" end,
        handler: fn _input, _opts -> raise "boom" end
      )

    assert {:ok, "callable:tool_exception:boom"} = Tool.invoke(callable_handler, %{})

    unhandled =
      Tool.from_function!(
        name: "unhandled_exploder",
        description: "Raises",
        input_schema: %{type: "object", required: []},
        handle_tool_error: false,
        handler: fn _input, _opts -> raise "boom" end
      )

    assert {:error, %Error{type: :tool_exception}} = Tool.invoke(unhandled, %{})

    assert {:ok, %Message{role: :tool, content: "handled", status: :error, tool_call_id: "call-err"}} =
             Tool.invoke(string_handler, %{
               type: "tool_call",
               name: "string_exploder",
               id: "call-err",
               args: %{}
             })
  end

  test "validation error handling policies format invalid input without executing handlers" do
    parent = self()

    validation_tool =
      Tool.from_function!(
        name: "needs_value",
        description: "Requires a value",
        input_schema: %{
          type: "object",
          properties: %{value: %{type: "string"}},
          required: [:value]
        },
        handle_validation_error: fn error ->
          "validation:#{Enum.join(error.details.missing, ",")}"
        end,
        handler: fn _input, _opts ->
          send(parent, :executed)
          "should not run"
        end
      )

    assert {:ok, "validation:value"} = Tool.invoke(validation_tool, %{})
    refute_received :executed

    bool_tool =
      %{validation_tool | handle_validation_error: true}

    assert {:ok, message} =
             Tool.invoke(bool_tool, %{
               "type" => "tool_call",
               "name" => "needs_value",
               "id" => "call-validation",
               "args" => %{}
             })

    assert %Message{
             role: :tool,
             content: "tool input is missing required keys",
             status: :error,
             tool_call_id: "call-validation"
           } = message

    string_tool = %{validation_tool | handle_validation_error: "bad input"}
    assert {:ok, "bad input"} = Tool.invoke(string_tool, %{})
    assert {:ok, "bad input"} = string_tool |> Tool.async_invoke(%{}) |> Async.await()

    unhandled = %{validation_tool | handle_validation_error: false}
    assert {:error, %Error{type: :invalid_input}} = Tool.invoke(unhandled, %{})

    raising_tool =
      %{
        validation_tool
        | handle_validation_error: true,
          handler: fn _input, _opts -> raise "not validation" end
      }

    assert {:error, %Error{type: :tool_exception, message: "not validation"}} =
             Tool.invoke(raising_tool, %{value: "ok"})
  end

  test "parse_args can coerce model arguments before schema validation" do
    tool =
      Tool.from_function!(
        name: "coerce_count",
        description: "Coerce count",
        input_schema: %{
          type: "object",
          properties: %{count: %{type: "integer"}},
          required: [:count]
        },
        parse_args: fn %{"count" => count} when is_binary(count) ->
          {:ok, %{"count" => String.to_integer(count)}}
        end,
        handler: fn %{"count" => count}, _opts -> count * 2 end
      )

    assert {:ok, 6} = Tool.invoke(tool, %{"count" => "3"})
  end

  test "parse_args :ok keeps arguments unchanged" do
    tool =
      Tool.from_function!(
        name: "passthrough",
        description: "Pass through",
        input_schema: %{type: "object", properties: %{value: %{type: "string"}}},
        parse_args: fn _args -> :ok end,
        handler: fn %{"value" => value}, _opts -> value end
      )

    assert {:ok, "ok"} = Tool.invoke(tool, %{"value" => "ok"})
  end

  test "parse_args failures use validation error handling policy" do
    parent = self()

    tool =
      Tool.from_function!(
        name: "parser_error",
        description: "Parser error",
        input_schema: %{type: "object"},
        parse_args: fn _args -> {:error, :bad_args} end,
        handle_validation_error: fn error -> "parse failed:#{error.details.reason}" end,
        handler: fn _args, _opts ->
          send(parent, :executed)
          "ran"
        end
      )

    assert {:ok, "parse failed::bad_args"} = Tool.invoke(tool, %{})
    refute_received :executed
  end

  test "parse_args exceptions and invalid return shapes become invalid input errors" do
    raising =
      Tool.from_function!(
        name: "raising_parser",
        description: "Raises in parser",
        input_schema: %{type: "object"},
        parse_args: fn _args -> raise "bad parse" end,
        handler: fn _args, _opts -> "ran" end
      )

    invalid =
      Tool.from_function!(
        name: "invalid_parser",
        description: "Invalid parser return",
        input_schema: %{type: "object"},
        parse_args: fn _args -> {:ok, "not a map"} end,
        handler: fn _args, _opts -> "ran" end
      )

    assert {:error, %Error{type: :invalid_input, message: "tool parse_args raised an exception"}} =
             Tool.invoke(raising, %{})

    assert {:error, %Error{type: :invalid_input, message: "tool parse_args returned a non-map"}} =
             Tool.invoke(invalid, %{})
  end

  test "hides runtime-injected arguments from public schemas and validation" do
    tool =
      Tool.from_function!(
        name: "search",
        description: "Searches with runtime context",
        input_schema: %{
          type: "object",
          properties: %{
            query: %{type: "string"},
            state: %{type: "object"},
            tool_runtime: %{type: "object"},
            tool_call_id: %{type: "string"}
          },
          required: [:query, :state, :tool_runtime, :tool_call_id]
        },
        injected: [state: :state, tool_runtime: :tool_runtime, tool_call_id: :tool_call_id],
        handler: fn input, _opts ->
          "#{input.query}:#{input.state.user}:#{input.tool_call_id}"
        end
      )

    assert Tool.raw_input_schema(tool).properties |> Map.keys() |> Enum.sort() ==
             [:query, :state, :tool_call_id, :tool_runtime]

    assert Tool.input_schema(tool) == %{
             type: "object",
             properties: %{query: %{type: "string"}},
             required: [:query]
           }

    assert :ok = Tool.validate_input(Tool.input_schema(tool), %{query: "cats"})

    assert {:ok, "cats:ada:call-1"} =
             Tool.invoke(tool, %{query: "cats", state: %{user: "ada"}, tool_call_id: "call-1"})
  end

  test "exposes BaseTool-style args, single-input, run, async, and tool-call schema helpers" do
    tool =
      Tool.from_function!(
        name: "lookup",
        description: "Looks up an item",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "tool_runtime" => %{"type" => "object"}
          },
          "required" => ["query", "tool_runtime"]
        },
        injected: %{"tool_runtime" => :tool_runtime},
        handler: fn input, opts ->
          {:ok, {input["query"], Keyword.get(opts, :tenant)}}
        end
      )

    assert Tool.args(tool) == %{"query" => %{"type" => "string"}}
    assert Tool.single_input?(tool)

    assert Tool.tool_call_schema(tool) == %{
             "name" => "lookup",
             "description" => "Looks up an item",
             "parameters" => %{
               "type" => "object",
               "properties" => %{"query" => %{"type" => "string"}},
               "required" => ["query"]
             }
           }

    assert {:ok, {"beam", "acme"}} = Tool.run(tool, %{"query" => "beam"}, tenant: "acme")

    handle = Tool.async_invoke(tool, %{"query" => "async"}, tenant: "acme")
    assert {:ok, {"async", "acme"}} = Async.await(handle)
  end

  test "single-input tools accept scalar values without Python positional APIs" do
    tool =
      Tool.from_function!(
        name: "echo",
        description: "Echoes one value",
        input_schema: %{
          type: "object",
          properties: %{query: %{type: "string"}},
          required: [:query]
        },
        handler: fn input, _opts -> input.query end
      )

    assert Tool.single_input?(tool)
    assert {:ok, "beam"} = Tool.invoke(tool, "beam")
  end

  test "tool_call inputs validate args, inject call id, and wrap output as tool messages" do
    tool =
      Tool.from_function!(
        name: "structured_api",
        description: "Structured API",
        input_schema: %{
          type: "object",
          properties: %{
            arg1: %{type: "integer"},
            arg2: %{type: "boolean"},
            arg3: %{type: ["object", "null"], default: nil},
            tool_call_id: %{type: "string"}
          },
          required: [:arg1, :arg2, :tool_call_id]
        },
        injected: [tool_call_id: :tool_call_id],
        handler: fn input, _opts ->
          "#{input.arg1} #{input.arg2} #{inspect(input.arg3)} #{input.tool_call_id}"
        end
      )

    tool_call = %{
      type: "tool_call",
      name: "structured_api",
      id: "123",
      args: %{arg1: 1, arg2: true}
    }

    assert {:ok,
            %Message{
              role: :tool,
              content: "1 true nil 123",
              tool_call_id: "123",
              name: "structured_api",
              status: :success
            }} = Tool.invoke(tool, tool_call)

    invalid_call = %{tool_call | args: %{arg1: 1}} |> Map.delete(:type)
    assert {:error, error} = Tool.invoke(tool, invalid_call)
    assert error.type == :invalid_input
  end

  test "tool_call invocation preserves provider call IDs and does not mutate inputs" do
    tool =
      Tool.from_function!(
        name: "echo",
        description: "Echoes a value",
        input_schema: %{
          type: "object",
          properties: %{value: %{type: "integer"}, tool_call_id: %{type: "string"}},
          required: [:value, :tool_call_id]
        },
        injected: [tool_call_id: :tool_call_id],
        handler: fn input, _opts -> "#{input.value}:#{input.tool_call_id}" end
      )

    tool_call = %{type: "tool_call", name: "echo", id: "", args: %{value: 42}}

    assert {:ok, %Message{content: "42:", tool_call_id: ""}} = Tool.invoke(tool, tool_call)
    assert tool_call == %{type: "tool_call", name: "echo", id: "", args: %{value: 42}}

    async_call = %{type: "tool_call", name: "echo", id: "async-id", args: %{value: 7}}

    assert {:ok, %Message{content: "7:async-id", tool_call_id: "async-id"}} =
             tool |> Tool.async_invoke(async_call) |> Async.await()

    assert async_call == %{type: "tool_call", name: "echo", id: "async-id", args: %{value: 7}}
  end

  test "content_and_artifact tools split raw invocation content and tool-call artifacts" do
    tool =
      Tool.from_function!(
        name: "artifact_tool",
        description: "Returns content and artifact",
        input_schema: %{
          type: "object",
          properties: %{value: %{type: "string"}},
          required: [:value]
        },
        response_format: :content_and_artifact,
        handler: fn input, _opts ->
          value = input[:value] || input["value"]
          {String.upcase(value), %{raw: value}}
        end
      )

    assert {:ok, "BEAM"} = Tool.invoke(tool, %{value: "beam"})

    assert {:ok, %Message{content: "BEAM", artifacts: [%{raw: "beam"}], tool_call_id: "call-1"}} =
             Tool.invoke(tool, %{
               "type" => "tool_call",
               "name" => "artifact_tool",
               "id" => "call-1",
               "args" => %{"value" => "beam"}
             })
  end

  test "format_output preserves structured tool outputs and wraps non-message content" do
    messages = [
      Message.tool("a", tool_call_id: "1", name: "t"),
      Message.tool("b", tool_call_id: "2", name: "t")
    ]

    assert Tool.format_output(messages, tool_call_id: "0", name: "t") == messages

    assert %Message{content: wrapped_content, tool_call_id: "0"} =
             Tool.format_output([hd(messages), "oops"], tool_call_id: "0", name: "t")

    assert wrapped_content =~ "oops"

    assert %Message{content: "[]", tool_call_id: "0"} =
             Tool.format_output([], tool_call_id: "0", name: "t")

    assert %Message{content: [%{type: :text, text: "ok"}], tool_call_id: "0"} =
             Tool.format_output([%{"type" => "text", "text" => "ok"}],
               tool_call_id: "0",
               name: "t"
             )

    result = ToolResult.success("done", artifact: %{trace: 1})
    assert Tool.format_output(result, tool_call_id: "0", name: "t") == result
  end

  test "tool_call invocation preserves lists of structured tool messages" do
    tool =
      Tool.from_function!(
        name: "multi",
        description: "Returns multiple tool messages",
        input_schema: %{
          type: "object",
          properties: %{count: %{type: "integer"}},
          required: [:count]
        },
        handler: fn input, _opts ->
          Enum.map(
            1..input.count,
            &Message.tool("result-#{&1}", tool_call_id: "sub-#{&1}", name: "multi")
          )
        end
      )

    assert {:ok, results} =
             Tool.invoke(tool, %{type: "tool_call", name: "multi", id: "outer", args: %{count: 3}})

    assert Enum.map(results, & &1.tool_call_id) == ["sub-1", "sub-2", "sub-3"]
  end

  test "stores explicit return_direct metadata on function tools" do
    direct =
      Tool.from_function!(
        name: "finish",
        description: "Finishes the agent loop",
        input_schema: %{},
        return_direct: true,
        handler: fn _input, _opts -> "done" end
      )

    normal =
      Tool.from_function!(
        name: "continue",
        description: "Continues the agent loop",
        input_schema: %{},
        handler: fn _input, _opts -> "ok" end
      )

    assert Tool.return_direct(direct)
    refute Tool.return_direct(normal)
  end

  test "rejects invalid schema property types before invoking the handler" do
    parent = self()

    tool =
      Tool.from_function!(
        name: "select_number",
        description: "Selects a number",
        input_schema: %{
          properties: %{value: %{type: "integer"}, label: %{type: ["string", "null"]}},
          required: [:value]
        },
        handler: fn input, _opts ->
          send(parent, {:executed, input})
          input
        end
      )

    assert {:error, error} = Tool.invoke(tool, %{value: "37", label: nil})
    assert error.type == :invalid_input
    assert error.message == "tool input has invalid type"
    assert error.details.key == :value
    assert error.details.expected == "integer"

    refute_receive {:executed, _input}

    assert {:ok, %{value: 37, label: nil}} = Tool.invoke(tool, %{value: 37, label: nil})
    assert_receive {:executed, %{value: 37, label: nil}}
  end
end
