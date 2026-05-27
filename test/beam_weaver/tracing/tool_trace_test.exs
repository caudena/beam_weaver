defmodule BeamWeaver.Tracing.ToolTraceTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Nodes.ToolNode
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Context
  alias BeamWeaver.Tracing.Store

  defmodule UnregisteredToolInterceptor do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :unregistered_tool_interceptor

    def wrap_tool_call(request, handler) do
      case request.tool_call.name do
        "magic_tool" ->
          Message.tool("magic:#{request.tool_call.args["value"]}",
            tool_call_id: request.tool_call.id,
            name: "magic_tool"
          )

        _other ->
          handler.(request)
      end
    end
  end

  defmodule RetryWrapper do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :retry_wrapper

    def wrap_tool_call(%ToolCallRequest{} = request, handler) do
      _ignored_first_attempt = handler.(request)
      handler.(request)
    end
  end

  setup do
    Tracing.reset()
    Context.clear()

    on_exit(fn ->
      Tracing.reset()
      Context.clear()
    end)

    :ok
  end

  test "Tool.invoke records neutral tool runs with public inputs only" do
    tool =
      Tool.from_function!(
        name: "search_docs",
        description: "Search project docs",
        input_schema: %{
          type: "object",
          properties: %{
            "query" => %{type: "string"},
            "state" => %{type: "object"}
          },
          required: ["query", "state"]
        },
        injected: %{"state" => :state},
        tags: [:retrieval],
        metadata: %{component: :docs},
        handler: fn input, _opts -> "found #{input["query"]}" end
      )

    {:ok, parent} = Tracing.start_run("agent", kind: :graph)

    assert {:ok, "found cats"} =
             Tool.invoke(tool, %{"query" => "cats", "state" => %{secret: "hidden"}}, tool_call_id: "call-search")

    assert {:ok, _finished_parent} = Tracing.finish_run(parent)

    assert [tool_run] = tool_runs()
    assert tool_run.parent_id == parent.id
    assert tool_run.trace_id == parent.trace_id
    assert tool_run.name == "search_docs"
    assert tool_run.inputs == %{"query" => "cats"}
    assert tool_run.outputs == %{output: "found cats"}
    assert tool_run.tags == ["tool", "retrieval"]
    assert tool_run.metadata.tool_name == "search_docs"
    assert tool_run.metadata.tool_call_id == "call-search"
    assert tool_run.metadata.description == "Search project docs"
    assert tool_run.metadata.component == :docs
  end

  test "handled tool and validation errors finish successfully while unhandled errors fail" do
    handled_validation =
      Tool.from_function!(
        name: "needs_value",
        description: "Needs value",
        input_schema: %{type: "object", required: ["value"]},
        handle_validation_error: true,
        handler: fn _input, _opts -> "should not run" end
      )

    handled_tool_error =
      Tool.from_function!(
        name: "handled_exploder",
        description: "Handled exception",
        input_schema: %{type: "object"},
        handle_tool_error: "handled boom",
        handler: fn _input, _opts -> raise "boom" end
      )

    unhandled_validation = %{handled_validation | handle_validation_error: false}

    unhandled_exception =
      Tool.from_function!(
        name: "unhandled_exploder",
        description: "Unhandled exception",
        input_schema: %{type: "object"},
        handle_tool_error: false,
        handler: fn _input, _opts -> raise "boom" end
      )

    {:ok, parent} = Tracing.start_run("agent", kind: :graph)

    assert {:ok, %Message{status: :error, tool_call_id: "call-validation"}} =
             Tool.invoke(handled_validation, %{
               type: "tool_call",
               name: "needs_value",
               id: "call-validation",
               args: %{}
             })

    assert {:ok, %Message{status: :error, content: "handled boom", tool_call_id: "call-tool"}} =
             Tool.invoke(handled_tool_error, %{
               type: "tool_call",
               name: "handled_exploder",
               id: "call-tool",
               args: %{}
             })

    assert {:error, %Error{type: :invalid_input}} =
             Tool.invoke(unhandled_validation, %{
               type: "tool_call",
               name: "needs_value",
               id: "call-unhandled-validation",
               args: %{}
             })

    assert {:error, %Error{type: :tool_exception}} =
             Tool.invoke(unhandled_exception, %{
               type: "tool_call",
               name: "unhandled_exploder",
               id: "call-unhandled-tool",
               args: %{}
             })

    assert {:ok, _finished_parent} = Tracing.finish_run(parent)

    runs = tool_runs()
    assert Enum.count(runs, &(&1.status == :ok)) == 2
    assert Enum.count(runs, &(&1.status == :error)) == 2

    assert Enum.find(runs, &(&1.metadata.tool_call_id == "call-validation")).outputs.output.status ==
             :error

    assert Enum.find(runs, &(&1.metadata.tool_call_id == "call-tool")).outputs.output.content ==
             "handled boom"

    assert Enum.find(runs, &(&1.metadata.tool_call_id == "call-unhandled-validation")).error.type ==
             :invalid_input

    assert Enum.find(runs, &(&1.metadata.tool_call_id == "call-unhandled-tool")).error.type ==
             :tool_exception
  end

  test "ToolNode creates only actual tool runs and keeps injected args out of trace inputs" do
    tool =
      Tool.from_function!(
        name: "private_search",
        description: "Private search",
        input_schema: %{
          type: "object",
          properties: %{
            "query" => %{type: "string"},
            "state" => %{type: "object"}
          },
          required: ["query", "state"]
        },
        injected: %{"state" => :state},
        handler: fn input, _opts -> "found #{input["query"]}" end
      )

    node = ToolNode.new([tool])
    {:ok, parent} = Tracing.start_run("agent", kind: :graph)

    assert [message] =
             ToolNode.invoke(
               node,
               [%{id: "call-private", name: "private_search", args: %{"query" => "cats"}}],
               %{previous_state: %{state_secret: "hidden"}}
             )

    assert message.content == "found cats"
    assert {:ok, _finished_parent} = Tracing.finish_run(parent)

    runs = Store.list()
    assert Enum.map(runs, & &1.kind) |> Enum.sort() == [:graph, :tool]

    assert [tool_run] = tool_runs()
    assert tool_run.parent_id == parent.id
    assert tool_run.metadata.tool_call_id == "call-private"
    assert tool_run.inputs == %{"query" => "cats"}
  end

  test "ToolNode skips tool runs for unknown tools and middleware short-circuits" do
    registered =
      Tool.from_function!(
        name: "registered",
        description: "Registered tool",
        input_schema: %{required: ["x"]},
        handler: fn %{"x" => x}, _opts -> "registered:#{x}" end
      )

    node = ToolNode.new([registered], wrap_tool_call: [UnregisteredToolInterceptor])
    {:ok, parent} = Tracing.start_run("agent", kind: :graph)

    assert [unknown, magic] =
             ToolNode.invoke(node, [
               %{id: "call-unknown", name: "missing_tool", args: %{}},
               %{id: "call-magic", name: "magic_tool", args: %{"value" => 42}}
             ])

    assert unknown.metadata.status == "error"
    assert magic.content == "magic:42"
    assert {:ok, _finished_parent} = Tracing.finish_run(parent)
    assert tool_runs() == []
  end

  test "ToolNode wrapper retries create multiple tool runs with the same tool_call_id" do
    tool =
      Tool.from_function!(
        name: "echo",
        description: "Echo",
        input_schema: %{required: ["value"]},
        handler: fn %{"value" => value}, _opts -> "echo:#{value}" end
      )

    node = ToolNode.new([tool], wrap_tool_call: [RetryWrapper])
    {:ok, parent} = Tracing.start_run("agent", kind: :graph)

    assert [message] =
             ToolNode.invoke(node, [
               %{id: "call-retry", name: "echo", args: %{"value" => "beam"}}
             ])

    assert message.content == "echo:beam"
    assert {:ok, _finished_parent} = Tracing.finish_run(parent)

    assert [first, second] = tool_runs()
    assert first.parent_id == parent.id
    assert second.parent_id == parent.id
    assert Enum.map([first, second], & &1.metadata.tool_call_id) == ["call-retry", "call-retry"]
    assert Enum.map([first, second], & &1.inputs) == [%{"value" => "beam"}, %{"value" => "beam"}]
  end

  defp tool_runs do
    Store.list()
    |> Enum.filter(&(&1.kind == :tool))
  end
end
